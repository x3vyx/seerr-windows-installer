# Registers the scheduled task that keeps Seerr updated. Run by the installer.
# Safe to re-run, including from inside an update started by this same task:
# replacing a task definition does not stop the instance that is running.

$ErrorActionPreference = 'Stop'

$script = Join-Path $PSScriptRoot 'Update-Seerr.ps1'
$powershell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'

$action = New-ScheduledTaskAction -Execute $powershell `
  -Argument "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$script`""

$trigger = New-ScheduledTaskTrigger -Daily -At '04:00'

# StartWhenAvailable catches up after a night with the PC off. The time limit
# must stay above the updater's worst case, an update plus a rollback, because
# the task being killed halfway would leave Seerr stopped.
$settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries `
  -DontStopIfGoingOnBatteries -RunOnlyIfNetworkAvailable `
  -ExecutionTimeLimit (New-TimeSpan -Hours 3) -MultipleInstances IgnoreNew

$principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest

Register-ScheduledTask -TaskName 'Seerr Auto Update' -Action $action -Trigger $trigger `
  -Settings $settings -Principal $principal -Force `
  -Description 'Installs new Seerr releases, with backup and automatic rollback.' | Out-Null
