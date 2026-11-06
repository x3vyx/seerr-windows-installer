<#
.SYNOPSIS
  Unattended updater for the Seerr Windows install.

.DESCRIPTION
  Runs as SYSTEM from the "Seerr Auto Update" scheduled task. When the release
  feed has a newer build it stops the service, backs up the database and
  settings, runs the new installer silently and waits for Seerr to answer with
  the new version. If that fails it restores the backup, reinstalls the
  previous version and skips the failed release until a newer one appears.

  Everything the task executes lives under the install dir, which only admins
  can write to. Never move the download cache to the data dir: that folder is
  user-writable, so a local user could swap the .exe that SYSTEM is about to
  run.

  Must stay compatible with Windows PowerShell 5.1 and stay pure ASCII (5.1
  reads BOM-less files as ANSI).

.PARAMETER CheckOnly
  Report whether an update is available and exit. Needs no elevation.

.PARAMETER InstallerPath
  Use this local installer instead of downloading one. Requires -TargetVersion.

.PARAMETER RollbackInstallerPath
  Local installer of the currently installed version, used if the update fails.
  Without it the updater looks in its cache, then in the release feed.
#>
[CmdletBinding()]
param(
  [string]$Repo = 'x3vyx/seerr-windows-installer',
  [switch]$CheckOnly,
  [switch]$Force,
  [string]$InstallerPath,
  [string]$TargetVersion,
  [string]$RollbackInstallerPath,
  [int]$HealthTimeoutSec = 300,
  [int]$InstallerTimeoutSec = 2400,
  [int]$KeepBackups = 5
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$ServiceName = 'Seerr'
$UninstallKey = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\{B5F0A1C2-4D9E-4A2A-9A3F-2C4F5E8B7A11}_is1'

# --- install layout ---------------------------------------------------------

$install = Get-ItemProperty -Path $UninstallKey -ErrorAction SilentlyContinue
if (-not $install) { throw 'Seerr is not installed (uninstall registry key not found).' }

$AppDir = $install.InstallLocation.TrimEnd('\')
$InstalledVersion = $install.DisplayVersion
$DataDir = (Get-ItemProperty -Path 'HKLM:\SOFTWARE\Seerr' -ErrorAction SilentlyContinue).DataDir
if (-not $DataDir) { $DataDir = Join-Path $env:ProgramData 'Seerr' }

$UpdaterDir = Join-Path $AppDir 'updater'
$CacheDir = Join-Path $UpdaterDir 'cache'
$LogFile = Join-Path $UpdaterDir 'update.log'
$StateFile = Join-Path $UpdaterDir 'state.json'
$BackupRoot = Join-Path $DataDir 'backups'

# --- helpers ----------------------------------------------------------------

function Write-Log([string]$Message) {
  $line = '{0:yyyy-MM-dd HH:mm:ss} {1}' -f (Get-Date), $Message
  Write-Host $line
  if (-not $CheckOnly) {
    if (-not (Test-Path $UpdaterDir)) { New-Item -ItemType Directory -Path $UpdaterDir -Force | Out-Null }
    Add-Content -Path $LogFile -Value $line -Encoding ASCII
  }
}

# "3.5.1" or "3.5.1-r2" -> sortable parts. Returns $null for anything else, so
# release candidates and other tag shapes are ignored rather than installed.
function ConvertTo-BuildVersion([string]$Text) {
  if ($Text -match '^v?(\d+\.\d+\.\d+)(?:-r(\d+))?$') {
    $revision = 0
    if ($Matches[2]) { $revision = [int]$Matches[2] }
    return [pscustomobject]@{
      Text     = ($Text -replace '^v', '')
      App      = [version]$Matches[1]
      Revision = $revision
    }
  }
  return $null
}

function Test-Newer($Candidate, $Baseline) {
  if ($Candidate.App -ne $Baseline.App) { return $Candidate.App -gt $Baseline.App }
  return $Candidate.Revision -gt $Baseline.Revision
}

function Get-Releases {
  $uri = "https://api.github.com/repos/$Repo/releases?per_page=50"
  $headers = @{ 'User-Agent' = 'seerr-windows-updater'; 'Accept' = 'application/vnd.github+json' }
  $response = Invoke-WebRequest -Uri $uri -Headers $headers -UseBasicParsing -TimeoutSec 60
  $releases = $response.Content | ConvertFrom-Json
  foreach ($release in $releases) {
    if ($release.draft -or $release.prerelease) { continue }
    $version = ConvertTo-BuildVersion $release.tag_name
    $asset = $release.assets | Where-Object { $_.name -like '*-windows-x64-setup.exe' } | Select-Object -First 1
    if ($version -and $asset) {
      [pscustomobject]@{ Tag = $release.tag_name; Version = $version; Asset = $asset }
    }
  }
}

function Get-VerifiedInstaller($Release) {
  if (-not (Test-Path $CacheDir)) { New-Item -ItemType Directory -Path $CacheDir -Force | Out-Null }
  $target = Join-Path $CacheDir $Release.Asset.name

  if (-not ($Release.Asset.digest -match '^sha256:([0-9a-fA-F]{64})$')) {
    throw "Release $($Release.Tag) has no sha256 digest for $($Release.Asset.name)."
  }
  $expected = $Matches[1]

  if ((Test-Path $target) -and (Get-FileHash $target -Algorithm SHA256).Hash -eq $expected) {
    Write-Log "Using cached $($Release.Asset.name)"
    return $target
  }

  Write-Log "Downloading $($Release.Asset.name)"
  $partial = "$target.partial"
  Invoke-WebRequest -Uri $Release.Asset.browser_download_url -OutFile $partial `
    -UseBasicParsing -TimeoutSec 1800 -Headers @{ 'User-Agent' = 'seerr-windows-updater' }

  $actual = (Get-FileHash $partial -Algorithm SHA256).Hash
  if ($actual -ne $expected) {
    Remove-Item $partial -Force
    throw "Checksum mismatch for $($Release.Asset.name): expected $expected, got $actual."
  }
  Move-Item $partial $target -Force
  return $target
}

function Get-ServicePort {
  $parameters = "HKLM:\SYSTEM\CurrentControlSet\Services\$ServiceName\Parameters"
  $environment = (Get-ItemProperty -Path $parameters -ErrorAction SilentlyContinue).AppEnvironmentExtra
  foreach ($entry in $environment) {
    if ($entry -match '^PORT=(\d+)$') { return [int]$Matches[1] }
  }
  return 5055
}

function Stop-Seerr {
  $service = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
  if (-not $service -or $service.Status -eq 'Stopped') { return }
  Write-Log 'Stopping service'
  Stop-Service -Name $ServiceName -Force
  $service.WaitForStatus('Stopped', [TimeSpan]::FromSeconds(60))
}

function Backup-Seerr {
  $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
  $backup = Join-Path $BackupRoot "$InstalledVersion-$stamp"
  New-Item -ItemType Directory -Path $backup -Force | Out-Null
  Copy-Item -Path (Join-Path $DataDir 'db') -Destination $backup -Recurse -Force
  Copy-Item -Path (Join-Path $DataDir 'settings.json') -Destination $backup -Force -ErrorAction SilentlyContinue
  Write-Log "Backed up database and settings to $backup"
  return $backup
}

function Restore-Seerr([string]$Backup) {
  # Clear first: a leftover -wal or -shm next to the restored database would
  # replay newer pages over it and corrupt it.
  $db = Join-Path $DataDir 'db'
  Remove-Item -Path (Join-Path $db '*') -Recurse -Force -ErrorAction SilentlyContinue
  Copy-Item -Path (Join-Path $Backup 'db\*') -Destination $db -Recurse -Force
  $settings = Join-Path $Backup 'settings.json'
  if (Test-Path $settings) { Copy-Item -Path $settings -Destination $DataDir -Force }
  Write-Log "Restored database and settings from $Backup"
}

function Remove-OldBackups {
  if (-not (Test-Path $BackupRoot)) { return }
  Get-ChildItem -Path $BackupRoot -Directory |
    Sort-Object -Property CreationTime -Descending |
    Select-Object -Skip $KeepBackups |
    ForEach-Object { Remove-Item -Path $_.FullName -Recurse -Force }
}

function Invoke-Installer([string]$Path) {
  $log = Join-Path $UpdaterDir 'last-install.log'
  Write-Log "Running $Path"
  $arguments = @('/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART', "/LOG=`"$log`"")
  $process = Start-Process -FilePath $Path -ArgumentList $arguments -PassThru
  $null = $process.Handle   # without a cached handle ExitCode stays empty on 5.1
  # Session 0 has no desktop, so a stuck installer would otherwise hang forever.
  if (-not $process.WaitForExit($InstallerTimeoutSec * 1000)) {
    $process.Kill()
    throw "Installer timed out after $InstallerTimeoutSec seconds."
  }
  if ($process.ExitCode -ne 0) { throw "Installer exited with code $($process.ExitCode)." }
}

# Answers both the API and a rendered page: the API alone can pass while the
# Next.js handler fails to load.
function Wait-Healthy([string]$ExpectedAppVersion) {
  $port = Get-ServicePort
  $deadline = (Get-Date).AddSeconds($HealthTimeoutSec)
  $seen = '(no answer)'
  while ((Get-Date) -lt $deadline) {
    try {
      $status = Invoke-RestMethod -Uri "http://127.0.0.1:$port/api/v1/status" -TimeoutSec 10
      $seen = $status.version
      if ($seen -eq $ExpectedAppVersion) {
        $page = Invoke-WebRequest -Uri "http://127.0.0.1:$port/login" -UseBasicParsing -TimeoutSec 30
        if ($page.StatusCode -eq 200) {
          Write-Log "Seerr $seen is healthy on port $port"
          return $true
        }
      }
    } catch {
      $seen = "(no answer: $($_.Exception.Message))"
    }
    Start-Sleep -Seconds 5
  }
  Write-Log "Health check failed after $HealthTimeoutSec seconds. Expected $ExpectedAppVersion, last saw $seen"
  return $false
}

function Read-State {
  if (Test-Path $StateFile) { return Get-Content $StateFile -Raw | ConvertFrom-Json }
  return [pscustomobject]@{ failedVersion = $null }
}

function Save-State([string]$FailedVersion) {
  [pscustomobject]@{ failedVersion = $FailedVersion; updatedAt = (Get-Date).ToString('o') } |
    ConvertTo-Json | Set-Content -Path $StateFile -Encoding ASCII
}

function Clear-Cache([string[]]$Keep) {
  Get-ChildItem -Path $CacheDir -File -ErrorAction SilentlyContinue |
    Where-Object { $Keep -notcontains $_.FullName } |
    Remove-Item -Force
}

# --- main -------------------------------------------------------------------

$mutex = New-Object System.Threading.Mutex($false, 'Global\SeerrAutoUpdate')
if (-not $mutex.WaitOne(0)) {
  Write-Log 'Another update is already running.'
  exit 0
}

try {
  $current = ConvertTo-BuildVersion $InstalledVersion
  if (-not $current) { throw "Cannot parse installed version '$InstalledVersion'." }

  $releases = @()
  if ($InstallerPath) {
    if (-not $TargetVersion) { throw '-InstallerPath requires -TargetVersion.' }
    $target = ConvertTo-BuildVersion $TargetVersion
    if (-not $target) { throw "Cannot parse target version '$TargetVersion'." }
  } else {
    $releases = @(Get-Releases)
    if ($releases.Count -eq 0) { throw "No usable releases found in $Repo." }
    $latest = $releases | Sort-Object -Property @{ Expression = { $_.Version.App } }, @{ Expression = { $_.Version.Revision } } |
      Select-Object -Last 1
    $target = $latest.Version
  }

  if (-not $InstallerPath -and -not (Test-Newer $target $current)) {
    Write-Log "Up to date: installed $($current.Text), latest $($target.Text)"
    exit 0
  }

  if ($CheckOnly) {
    Write-Log "Update available: installed $($current.Text), latest $($target.Text)"
    exit 0
  }

  $state = Read-State
  if (-not $Force -and $state.failedVersion -eq $target.Text) {
    Write-Log "Skipping $($target.Text): it failed before. Waiting for a newer release, or run with -Force."
    exit 0
  }

  Write-Log "Updating $($current.Text) -> $($target.Text)"

  # Collect everything needed for a rollback before touching the install.
  if ($RollbackInstallerPath) {
    $rollbackInstaller = $RollbackInstallerPath
  } else {
    $previous = $releases | Where-Object { $_.Version.Text -eq $current.Text } | Select-Object -First 1
    if (-not $previous) {
      throw "No installer for the installed version $($current.Text) in $Repo, so a failed update could not be rolled back. Aborting."
    }
    $rollbackInstaller = Get-VerifiedInstaller $previous
  }

  if ($InstallerPath) { $newInstaller = $InstallerPath } else { $newInstaller = Get-VerifiedInstaller $latest }

  Stop-Seerr
  $backup = Backup-Seerr

  $healthy = $false
  try {
    Invoke-Installer $newInstaller
    $healthy = Wait-Healthy $target.App.ToString()
  } catch {
    Write-Log "Update failed: $($_.Exception.Message)"
  }

  if ($healthy) {
    Save-State $null
    Remove-OldBackups
    Clear-Cache @($newInstaller)
    Write-Log "Updated to $($target.Text)"
    exit 0
  }

  Write-Log "Rolling back to $($current.Text)"
  Stop-Seerr
  # Older installers do not clear this folder, and mixing two builds breaks it.
  # rd, because Remove-Item takes many minutes on a folder this size.
  & cmd.exe /c rd /s /q (Join-Path $AppDir 'app')
  Restore-Seerr $backup
  Invoke-Installer $rollbackInstaller
  Save-State $target.Text

  if (Wait-Healthy $current.App.ToString()) {
    Write-Log "Rolled back to $($current.Text). Skipping $($target.Text) until a newer release."
    exit 1
  }
  Write-Log "ROLLBACK FAILED. Seerr is not answering. Data backup: $backup"
  exit 2
} catch {
  Write-Log "ERROR: $($_.Exception.Message)"
  exit 1
} finally {
  $mutex.ReleaseMutex()
  $mutex.Dispose()
}
