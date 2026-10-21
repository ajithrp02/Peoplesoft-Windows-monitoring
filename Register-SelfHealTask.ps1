# Run once as Administrator. Schedules the self-healing agent every N minutes as SYSTEM.
param(
    [string]$ScriptPath = "$PSScriptRoot\PSSelfHeal.ps1",
    [int]$EveryMinutes = 60,
    [string]$TaskName = 'PeopleSoft Self-Heal Agent'
)
$action   = New-ScheduledTaskAction -Execute 'powershell.exe' `
            -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$ScriptPath`"" -WorkingDirectory (Split-Path $ScriptPath)
$trigger  = New-ScheduledTaskTrigger -Once -At (Get-Date).Date -RepetitionInterval (New-TimeSpan -Minutes $EveryMinutes)
$settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Minutes 30) -MultipleInstances IgnoreNew
$principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) { Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false }
Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Settings $settings -Principal $principal
Write-Host "Registered '$TaskName' every $EveryMinutes min. Test: Start-ScheduledTask -TaskName '$TaskName'"
