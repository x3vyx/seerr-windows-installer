<#
.SYNOPSIS
  Exercises the real update path on a throwaway CI runner before a release is
  published: rollback from a failed update, then a successful upgrade.

  This installs a Windows service, so do not run it on a machine you care about.
#>
param(
  [Parameter(Mandatory)] [string]$NewInstaller,
  [Parameter(Mandatory)] [string]$NewVersion,
  [Parameter(Mandatory)] [string]$BaselineInstaller,
  [Parameter(Mandatory)] [string]$BaselineVersion
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$updater = Join-Path $PSScriptRoot '..\installer\updater\Update-Seerr.ps1'
$dataDir = Join-Path $env:ProgramData 'Seerr'
$nssm = 'C:\Program Files\Seerr\service\nssm.exe'
$appVersion = $NewVersion -replace '-r\d+$', ''
$baselineAppVersion = $BaselineVersion -replace '-r\d+$', ''

function Assert-True([bool]$Condition, [string]$Message) {
  if (-not $Condition) { throw "FAILED: $Message" }
  Write-Host "ok: $Message"
}

function Wait-Version([string]$Expected, [int]$Port) {
  $deadline = (Get-Date).AddMinutes(5)
  while ((Get-Date) -lt $deadline) {
    try {
      $status = Invoke-RestMethod "http://127.0.0.1:$Port/api/v1/status" -TimeoutSec 10
      if ($status.version -eq $Expected) { return $status }
    } catch { }
    Start-Sleep -Seconds 5
  }
  Get-Content (Join-Path $dataDir 'logs\service-stderr.log') -Tail 40 -ErrorAction SilentlyContinue
  throw "Seerr $Expected did not answer on port $Port"
}

function Get-ClientId {
  (Get-Content (Join-Path $dataDir 'settings.json') -Raw | ConvertFrom-Json).clientId
}

function Invoke-Updater([string[]]$Arguments) {
  & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $updater @Arguments | Out-Host
  return $LASTEXITCODE
}

Write-Host "=== Baseline install ($BaselineVersion)"
$process = Start-Process $BaselineInstaller -ArgumentList '/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART' -PassThru
$null = $process.Handle
Assert-True ($process.WaitForExit(2400000) -and $process.ExitCode -eq 0) 'baseline installer finished'
Wait-Version $baselineAppVersion 5055 | Out-Null
$clientId = Get-ClientId
Assert-True ([bool]$clientId) 'settings.json was created'

Write-Host '=== Failed update must roll back'
# 9.9.9 can never match what the new build reports, so the health check fails
# after a complete install and the rollback runs for real.
$exit = Invoke-Updater @('-InstallerPath', $NewInstaller, '-TargetVersion', '9.9.9',
  '-RollbackInstallerPath', $BaselineInstaller, '-HealthTimeoutSec', '60')
Assert-True ($exit -eq 1) "updater reported a rolled-back update (exit $exit)"
Wait-Version $baselineAppVersion 5055 | Out-Null
Assert-True ((Get-ClientId) -eq $clientId) 'settings survived the rollback'
$state = Get-Content 'C:\Program Files\Seerr\updater\state.json' -Raw | ConvertFrom-Json
Assert-True ($state.failedVersion -eq '9.9.9') 'failed release is remembered'

Write-Host '=== Failed release is skipped on the next run'
$exit = Invoke-Updater @('-InstallerPath', $NewInstaller, '-TargetVersion', '9.9.9',
  '-RollbackInstallerPath', $BaselineInstaller)
Assert-True ($exit -eq 0) 'updater skipped the failed release'

Write-Host '=== Successful update keeps a custom port'
& $nssm set Seerr AppEnvironmentExtra 'NODE_ENV=production' "CONFIG_DIRECTORY=$dataDir" 'PORT=5056' | Out-Null
Restart-Service Seerr -Force
Wait-Version $baselineAppVersion 5056 | Out-Null

$exit = Invoke-Updater @('-InstallerPath', $NewInstaller, '-TargetVersion', $NewVersion,
  '-RollbackInstallerPath', $BaselineInstaller)
Assert-True ($exit -eq 0) "updater succeeded (exit $exit)"

$status = Wait-Version $appVersion 5056
Assert-True ($status.commitTag -ne 'local') "commitTag is set ($($status.commitTag))"
Assert-True ((Get-ClientId) -eq $clientId) 'settings survived the update'
Assert-True (Test-Path 'C:\Program Files\Seerr\app\committag.json') 'committag.json was installed'

$page = Invoke-WebRequest 'http://127.0.0.1:5056/login' -UseBasicParsing -TimeoutSec 30
Assert-True ($page.StatusCode -eq 200) 'web UI renders'

$task = Get-ScheduledTask -TaskName 'Seerr Auto Update' -ErrorAction SilentlyContinue
Assert-True ([bool]$task) 'scheduled task is registered'
Assert-True ($task.Principal.UserId -eq 'SYSTEM') 'scheduled task runs as SYSTEM'

$backups = @(Get-ChildItem (Join-Path $dataDir 'backups') -Directory)
Assert-True ($backups.Count -ge 2) "backups were kept ($($backups.Count))"

Write-Host '=== All upgrade tests passed'
