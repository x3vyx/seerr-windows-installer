<#
.SYNOPSIS
  Starts the installer build when Seerr has a release this repo has not packaged.

.DESCRIPTION
  GitHub's cron never fired on this fork, even with the workflow active, so this
  runs hourly from a scheduled task on the PC instead. It uses the signed-in gh
  CLI, which keeps its token in the user's credential store, so the task has to
  run as that user and no token is stored anywhere new.

  Run with -Register once to create the task. Needs no elevation.

.PARAMETER PretendLatest
  Treat this tag as upstream's latest, to test the decision. Use with -DryRun.

.PARAMETER DryRun
  Report what would happen without starting a build.
#>
[CmdletBinding()]
param(
  [string]$Repo = 'x3vyx/seerr-windows-installer',
  [switch]$Register,
  [switch]$DryRun,
  [string]$PretendLatest
)

$ErrorActionPreference = 'Stop'

$TaskName = 'Seerr Build Trigger'
$LogDir = Join-Path $env:LOCALAPPDATA 'SeerrBuildTrigger'
$LogFile = Join-Path $LogDir 'trigger.log'
$Gh = Join-Path $env:ProgramFiles 'GitHub CLI\gh.exe'

function Write-Log([string]$Message) {
  $line = '{0:yyyy-MM-dd HH:mm:ss} {1}' -f (Get-Date), $Message
  Write-Host $line
  if (-not (Test-Path $LogDir)) { New-Item -ItemType Directory -Path $LogDir -Force | Out-Null }
  Add-Content -Path $LogFile -Value $line -Encoding ASCII
}

function Invoke-Gh([string[]]$Arguments) {
  $output = & $Gh @Arguments
  if ($LASTEXITCODE -ne 0) { throw "gh $($Arguments -join ' ') failed with exit $LASTEXITCODE" }
  return $output
}

if ($Register) {
  # conhost --headless, or a console window would flash up every hour.
  $powershell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
  $action = New-ScheduledTaskAction -Execute (Join-Path $env:SystemRoot 'System32\conhost.exe') `
    -Argument "--headless `"$powershell`" -NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$PSCommandPath`""
  $trigger = New-ScheduledTaskTrigger -Once -At (Get-Date).Date.AddMinutes(23) `
    -RepetitionInterval (New-TimeSpan -Hours 1)
  $settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries -RunOnlyIfNetworkAvailable `
    -ExecutionTimeLimit (New-TimeSpan -Minutes 5) -MultipleInstances IgnoreNew
  $principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType Interactive -RunLevel Limited
  Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Settings $settings `
    -Principal $principal -Force -Description 'Starts the Seerr installer build when upstream has a new release.' | Out-Null
  Write-Host "Registered '$TaskName'"
  exit 0
}

try {
  if ($PretendLatest) {
    $latest = $PretendLatest
  } else {
    $latest = Invoke-Gh @('api', 'repos/seerr-team/seerr/releases/latest', '--jq', '.tag_name')
  }

  $tags = @(Invoke-Gh @('api', "repos/$Repo/releases?per_page=100", '--jq', '.[].tag_name'))
  $packaged = @($tags | Where-Object { $_ -eq $latest -or $_ -like "$latest-r*" })
  if ($packaged.Count -gt 0) {
    Write-Log "Up to date: $latest is already packaged"
    exit 0
  }

  # A build takes over an hour with its tests, so the next check lands mid-run.
  # Filtered here, not with --jq: PowerShell 5.1 strips the double quotes a jq
  # string needs when it calls a native program.
  $statuses = @(Invoke-Gh @('run', 'list', '--repo', $Repo, '--workflow', 'build.yml', '--limit', '10',
      '--json', 'status', '--jq', '.[].status'))
  $active = @($statuses | Where-Object { $_ -ne 'completed' })
  if ($active.Count -gt 0) {
    Write-Log "$latest is new, but a build is already running"
    exit 0
  }

  if ($DryRun) {
    Write-Log "$latest is new, would start a build (dry run)"
    exit 0
  }

  Invoke-Gh @('workflow', 'run', 'build.yml', '--repo', $Repo, '--ref', 'main', '-f', "seerr_ref=$latest") | Out-Null
  Write-Log "$latest is new, build started"
} catch {
  Write-Log "ERROR: $($_.Exception.Message)"
  exit 1
}
