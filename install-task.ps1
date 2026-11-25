<#
.SYNOPSIS
    "WingetDailyUpdate" vazifasini Task Scheduler'ga ro'yxatdan o'tkazadi.

.DESCRIPTION
    Administrator huquqi bilan ishga tushirilishi shart (bir marta UAC tasdiqlanadi).
    Trigger: logon + N daqiqa kechikish. RunLevel: Highest.
    Qayta ishga tushirish xavfsiz (-Force bilan qayta yoziladi).

.PARAMETER TaskName
    Task nomi. Standart: WingetDailyUpdate.

.PARAMETER DelayMinutes
    Logon'dan keyin necha daqiqa kutish. Standart: 3.

.PARAMETER RunAsUser
    Task qaysi hisob nomidan ishlaydi. Bo'sh bo'lsa - joriy hisob.
#>
[CmdletBinding()]
param(
    [string]$TaskName = 'WingetDailyUpdate',
    [ValidateRange(0, 120)]
    [int]$DelayMinutes = 3,
    [string]$RunAsUser = "$env:USERDOMAIN\$env:USERNAME"
)

$ErrorActionPreference = 'Stop'

$identity  = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object Security.Principal.WindowsPrincipal($identity)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host 'Bu skript administrator huquqi bilan ishga tushirilishi kerak.' -ForegroundColor Red
    Write-Host 'PowerShell ni "Run as administrator" qilib ochib, qayta urinib ko''ring.' -ForegroundColor Yellow
    exit 1
}

$scriptPath = Join-Path $PSScriptRoot 'winget-daily.ps1'
if (-not (Test-Path $scriptPath)) { throw "winget-daily.ps1 topilmadi: $scriptPath" }

$configPath = Join-Path $PSScriptRoot 'config.json'
if (-not (Test-Path $configPath)) {
    $defaultConfig = @'
{
  "mode": "auto",
  "timeoutMinutes": 60,
  "silent": true,
  "notify": true,
  "notifyNoUpdates": true,
  "logRetentionDays": 30
}
'@
    Set-Content -Path $configPath -Value $defaultConfig -Encoding UTF8
    Write-Host 'config.json yaratildi.' -ForegroundColor Cyan
}

if (-not (Get-Command 'winget.exe' -ErrorAction SilentlyContinue)) {
    Write-Host "OGOHLANTIRISH: winget.exe topilmadi. App Installer o'rnatilganini tekshiring." -ForegroundColor Yellow
}

$user = $RunAsUser

$action = New-ScheduledTaskAction `
    -Execute 'powershell.exe' `
    -Argument ('-NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}"' -f $scriptPath) `
    -WorkingDirectory $PSScriptRoot

$trigger = New-ScheduledTaskTrigger -AtLogOn -User $user
$trigger.Delay = ('PT{0}M' -f $DelayMinutes)

$settings = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -DontStopOnIdleEnd `
    -StartWhenAvailable `
    -MultipleInstances IgnoreNew `
    -ExecutionTimeLimit (New-TimeSpan -Minutes 90) `
    -RestartCount 3 `
    -RestartInterval (New-TimeSpan -Minutes 10)

$taskPrincipal = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Highest

Register-ScheduledTask `
    -TaskName $TaskName `
    -Action $action `
    -Trigger $trigger `
    -Settings $settings `
    -Principal $taskPrincipal `
    -Description ('Har kuni logon + {0} daqiqada winget yangilanishlarini tekshiradi va yangilaydi.' -f $DelayMinutes) `
    -Force | Out-Null

Write-Host ''
Write-Host ('Task ro''yxatdan o''tdi: {0} (logon + {1} daqiqa)' -f $TaskName, $DelayMinutes) -ForegroundColor Green
Get-ScheduledTask -TaskName $TaskName | Select-Object TaskName, State | Format-Table -AutoSize
