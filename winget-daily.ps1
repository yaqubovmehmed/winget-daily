<#
.SYNOPSIS
    Kunlik winget yangilanishlari: tekshiradi va (auto rejimda) "winget upgrade --all" bajaradi.

.DESCRIPTION
    Task Scheduler "WingetDailyUpdate" har kuni "logon + 10 daqiqa" da ishga tushiradi.
      mode = report  -> faqat tekshiradi, ro'yxatni logga yozadi
      mode = auto    -> winget upgrade --all bajaradi
    Natija: last-run.json + logs\YYYY-MM-DD.log + Windows toast.

    Biror paketni yangilashni xohlamasangiz, winget'ning o'z mexanizmi:
        winget pin add --id <PaketId>
        winget pin remove --id <PaketId>

.PARAMETER Force
    Kunlik chegarani chetlab o'tib, majburan ishga tushirish.

.PARAMETER Mode
    config.json dagi rejimni faqat shu ishga tushirish uchun almashtirish.

.PARAMETER SelfTest
    Parserni namunaviy matnda sinaydi. Hech narsa o'zgartirmaydi.
#>
[CmdletBinding()]
param(
    [switch]$Force,
    [ValidateSet('report', 'auto')]
    [string]$Mode,
    [switch]$SelfTest
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$ScriptVersion = '2.0.1'

$Root        = $PSScriptRoot
$ConfigPath  = Join-Path $Root 'config.json'
$LogDir      = Join-Path $Root 'logs'
$LastRunPath = Join-Path $Root 'last-run.json'
$StatePath   = Join-Path $Root 'run-state.json'
$LogFile     = Join-Path $LogDir ((Get-Date).ToString('yyyy-MM-dd') + '.log')

if (-not (Test-Path $LogDir)) { New-Item -ItemType Directory -Path $LogDir -Force | Out-Null }

# Oxirgi himoya: kutilmagan xato hech qachon jimgina yo'qolmasin.
trap {
    try {
        $crash = '[{0}] [CRASH] {1} (qator: {2})' -f (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'), $_.Exception.Message, $_.InvocationInfo.ScriptLineNumber
        [IO.File]::AppendAllText($LogFile, $crash + "`r`n", (New-Object System.Text.UTF8Encoding($false)))
    } catch { }
    exit 1
}

$Sources = @('winget', 'msstore', 'winget-font')

# ---------------------------------------------------------------- logging ---
function Write-Log {
    param(
        [Parameter(Mandatory)][string]$Message,
        [ValidateSet('INFO', 'WARN', 'ERROR')][string]$Level = 'INFO'
    )
    $line = '[{0}] [{1}] {2}' -f (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'), $Level, $Message
    # avval faylga yozamiz - konsol yo'q bo'lsa ham yozuv saqlanadi
    try {
        [IO.File]::AppendAllText($LogFile, $line + "`r`n", (New-Object System.Text.UTF8Encoding($false)))
    } catch { }
    # Write-Host hech qachon skriptni to'xtatmasin (konsol yopilgan bo'lishi mumkin)
    try {
        switch ($Level) {
            'WARN'  { Write-Host $line -ForegroundColor Yellow }
            'ERROR' { Write-Host $line -ForegroundColor Red }
            default { Write-Host $line }
        }
    } catch { }
}

<#
    Jarayon "tirikligi" belgisi. Agar skript tashqaridan o'ldirilsa, bu fayl
    oxirgi bosqich va vaqtni saqlab qoladi - keyingi ishga tushirishda sabab ko'rinadi.
#>
function Set-RunState {
    param([Parameter(Mandatory)][string]$Phase)
    try {
        $obj = [ordered]@{
            ProcessId     = $PID
            startedAt     = $script:RunStartedAt
            phase         = $Phase
            lastHeartbeat = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
        }
        $obj | ConvertTo-Json -Depth 3 | Set-Content -Path $StatePath -Encoding UTF8
    } catch { }
}

# ----------------------------------------------------------------- config ---
function Read-Config {
    $defaults = [ordered]@{
        mode             = 'report'
        timeoutMinutes   = 60
        silent           = $true
        notify           = $true
        notifyNoUpdates  = $true
        logRetentionDays = 30
    }
    if (-not (Test-Path $ConfigPath)) { return [pscustomobject]$defaults }
    try {
        $c = Get-Content -Path $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
        foreach ($k in $defaults.Keys) {
            if ($null -eq $c.PSObject.Properties[$k]) {
                $c | Add-Member -NotePropertyName $k -NotePropertyValue $defaults[$k] -Force
            }
        }
        return $c
    } catch {
        Write-Log "config.json o'qilmadi, standart sozlamalar ishlatiladi: $($_.Exception.Message)" -Level WARN
        return [pscustomobject]$defaults
    }
}

function Rotate-Logs {
    param([int]$Days = 30)
    if ($Days -lt 1) { return }
    $limit = (Get-Date).AddDays(-$Days)
    Get-ChildItem -Path $LogDir -Filter '*.log' -ErrorAction SilentlyContinue |
        Where-Object { $_.LastWriteTime -lt $limit } |
        ForEach-Object {
            try { Remove-Item $_.FullName -Force; Write-Log "Eski log o'chirildi: $($_.Name)" } catch { }
        }
}

# ----------------------------------------------------------------- winget ---
function Get-WingetPath {
    $cmd = Get-Command 'winget.exe' -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    $candidates = @(
        (Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps\winget.exe'),
        'C:\Program Files\WindowsApps\Microsoft.DesktopAppInstaller_8wekyb3d8bbwe\winget.exe'
    )
    foreach ($c in $candidates) { if (Test-Path $c) { return $c } }
    return $null
}

# winget ba'zan UTF-8, ba'zan OEM (866) kodlashda yozadi - ikkisini ham tushunamiz
function ConvertFrom-OutputBytes {
    param([byte[]]$Bytes)
    if (-not $Bytes -or $Bytes.Length -eq 0) { return '' }
    try {
        $strict = New-Object System.Text.UTF8Encoding($false, $true)
        return $strict.GetString($Bytes).TrimStart([char]0xFEFF)
    } catch {
        $cp = [Globalization.CultureInfo]::CurrentCulture.TextInfo.OEMCodePage
        return [Text.Encoding]::GetEncoding($cp).GetString($Bytes)
    }
}

function Invoke-Winget {
    param(
        [Parameter(Mandatory)][string[]]$Arguments,
        [int]$TimeoutSec = 3600
    )
    $winget = Get-WingetPath
    if (-not $winget) { throw 'winget.exe topilmadi (App Installer o''rnatilmagan?)' }

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName               = $winget
    $psi.Arguments              = (($Arguments | ForEach-Object { if ($_ -match '\s') { '"{0}"' -f $_ } else { $_ } }) -join ' ')
    $psi.UseShellExecute        = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError  = $true
    $psi.CreateNoWindow         = $true

    $proc = New-Object System.Diagnostics.Process
    $proc.StartInfo = $psi
    $null = $proc.Start()

    $outMs = New-Object System.IO.MemoryStream
    $errMs = New-Object System.IO.MemoryStream
    $outTask = $proc.StandardOutput.BaseStream.CopyToAsync($outMs)
    $errTask = $proc.StandardError.BaseStream.CopyToAsync($errMs)

    # kutishni bo'laklab bajaramiz: har 15 soniyada "tiriklik" belgisini yozamiz.
    # Shu bilan skript o'ldirilgan bo'lsa, qaysi daqiqada o'lgani ma'lum bo'ladi.
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    $timedOut = $false
    $lastBeat = Get-Date
    while ($true) {
        if ($proc.WaitForExit(2000)) { break }
        if ((Get-Date) -ge $deadline) { $timedOut = $true; break }
        if (((Get-Date) - $lastBeat).TotalSeconds -ge 15) {
            $lastBeat = Get-Date
            Set-RunState -Phase ('winget {0} bajarilmoqda' -f $Arguments[0])
        }
    }

    if ($timedOut) {
        # butun jarayon daraxtini o'ldirish: osilib qolgan installer oynasi qolmasin
        try { & taskkill.exe /PID $proc.Id /T /F 2>&1 | Out-Null } catch { }
        try { if (-not $proc.HasExited) { $proc.Kill() } } catch { }
        $null = $proc.WaitForExit(5000)
    }

    $out = ''
    $err = ''
    try { if ($outTask.Wait(10000)) { $out = ConvertFrom-OutputBytes -Bytes $outMs.ToArray() } } catch { }
    try { if ($errTask.Wait(10000)) { $err = ConvertFrom-OutputBytes -Bytes $errMs.ToArray() } } catch { }

    $code = $null
    try { $code = $proc.ExitCode } catch { }
    try { $outMs.Dispose(); $errMs.Dispose(); $proc.Dispose() } catch { }

    return [pscustomobject]@{
        Output   = (($out + "`r`n" + $err).Trim())
        ExitCode = $code
        TimedOut = $timedOut
    }
}

<#
    winget jadvali: Name | Id | Version | Available | Source
    Til muhim emas - sarlavha/footer satrlari ID/versiya formatiga mos kelmaydi.
#>
function ConvertFrom-WingetTable {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)

    $rows = New-Object System.Collections.ArrayList

    foreach ($line in ($Text -split "`r?`n")) {
        if ($line -notmatch '\S') { continue }
        if ($line -match '^\s*[-=_]{3,}') { continue }

        $tokens = @($line.Trim() -split '\s+' | Where-Object { $_ -ne '' })
        if ($tokens.Count -lt 4) { continue }

        $last = $tokens[$tokens.Count - 1]
        if ($Sources -contains $last) {
            if ($tokens.Count -lt 5) { continue }
            $src   = $last
            $avail = $tokens[$tokens.Count - 2]
            $ver   = $tokens[$tokens.Count - 3]
            $id    = $tokens[$tokens.Count - 4]
            $name  = ($tokens[0..($tokens.Count - 5)] -join ' ')
        } else {
            $src   = ''
            $avail = $last
            $ver   = $tokens[$tokens.Count - 2]
            $id    = $tokens[$tokens.Count - 3]
            $name  = ($tokens[0..($tokens.Count - 4)] -join ' ')
        }

        if ($id -notmatch '^[A-Za-z0-9][A-Za-z0-9\.\-\+_]*$') { continue }
        if ($avail -notmatch '\d') { continue }
        if ([string]::IsNullOrWhiteSpace($name)) { continue }

        [void]$rows.Add([pscustomobject]@{
            Name      = $name.Trim()
            Id        = $id
            Version   = $ver
            Available = $avail
            Source    = $src
        })
    }

    return @($rows)
}

function Get-Upgradable {
    param([int]$TimeoutSec = 300)
    $res = Invoke-Winget -Arguments @('upgrade', '--include-unknown', '--accept-source-agreements', '--disable-interactivity') -TimeoutSec $TimeoutSec

    if ($res.TimedOut) {
        throw ("winget upgrade ro'yxati {0} soniyada olinmadi (timeout)" -f $TimeoutSec)
    }

    $rows = @(ConvertFrom-WingetTable -Text $res.Output)

    # 0 qator + noldan farqli exit code: "yangilanish yo'q" emas, haqiqiy xato bo'lishi mumkin
    if ($rows.Count -eq 0 -and $res.ExitCode -ne 0) {
        $okMessages = '(?i)no installed package|no applicable upgrade|применимые обновления не найдены|не найдены установленные|нет доступных обновлений|обновлений не найдено'
        if ($res.Output -notmatch $okMessages) {
            throw ("winget upgrade xato bilan tugadi (exit code {0})" -f $res.ExitCode)
        }
    }

    return $rows
}

# ------------------------------------------------------------------ toast ---
function Send-Toast {
    param(
        [Parameter(Mandatory)][string]$Title,
        [string]$Body = ''
    )
    try {
        $null = [Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime]
        $null = [Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom.XmlDocument, ContentType = WindowsRuntime]
        $xml = [Windows.UI.Notifications.ToastNotificationManager]::GetTemplateContent([Windows.UI.Notifications.ToastTemplateType]::ToastText02)
        $texts = $xml.GetElementsByTagName('text')
        [void]$texts.Item(0).AppendChild($xml.CreateTextNode($Title))
        [void]$texts.Item(1).AppendChild($xml.CreateTextNode($Body))
        $toast = [Windows.UI.Notifications.ToastNotification]::new($xml)
        $aumid = '{1AC14E77-02E7-4E5D-B744-2EB1AE5198B7}\WindowsPowerShell\v1.0\powershell.exe'
        [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier($aumid).Show($toast)
        Write-Log "Toast ko'rsatildi: $Title"
    } catch {
        Write-Log "Toast ko'rsatilmadi: $($_.Exception.Message)" -Level WARN
    }
}

function Format-PkgList {
    param($Packages, [int]$Max = 3)
    $all = @($Packages)
    if ($all.Count -eq 0) { return '' }
    $names = @($all | Select-Object -First $Max | ForEach-Object { $_.Name })
    $text = ($names -join ', ')
    if ($all.Count -gt $Max) { $text += (' va yana {0} ta' -f ($all.Count - $Max)) }
    return $text
}

# --------------------------------------------------------------- self-test ---
if ($SelfTest) {
    $sample = @'
Name                             Id                          Version      Available    Source
---------------------------------------------------------------------------------------------
Google Chrome                    Google.Chrome               131.0.6778 132.0.6834   winget
Microsoft Visual Studio Code     Microsoft.VisualStudioCode  1.96.2      1.97.0       winget
Node.js 20.1.0                   OpenJS.NodeJS               20.1.0      20.11.0      winget
WhatsApp                        9NBLGGH4NNS1                2.2400.2.0  2.2501.1.0   msstore
Firefox                          Mozilla.Firefox             Неизвестно  133.0        winget
Some App With No Source          Vendor.App                  1.0.0       1.2.0
Not a real row
6 обновлений доступно.
'@
    $parsed = ConvertFrom-WingetTable -Text $sample
    Write-Host ("Parselangan qatorlar: {0} (kutilgan: 6)" -f $parsed.Count) -ForegroundColor Cyan
    $parsed | Format-Table Name, Id, Version, Available, Source -AutoSize
    exit 0
}

# -------------------------------------------------------------------- main ---
$runStart = Get-Date
$script:RunStartedAt = $runStart.ToString('yyyy-MM-dd HH:mm:ss')
$mutex = New-Object System.Threading.Mutex($false, 'Local\WingetDailyUpdate')
$locked = $false
try {
    $locked = $mutex.WaitOne(0)
} catch [System.Threading.AbandonedMutexException] {
    Write-Log "Oldingi nusxa to'g'ri tugamagan (abandoned mutex) - davom etamiz." -Level WARN
    $locked = $true
}
if (-not $locked) {
    Write-Log "Boshqa nusxa allaqachon ishlayapti - chiqamiz." -Level WARN
    exit 0
}

$result = [ordered]@{
    date         = $runStart.ToString('yyyy-MM-dd')
    startedAt    = $runStart.ToString('yyyy-MM-dd HH:mm:ss')
    finishedAt   = $null
    mode         = $null
    status       = 'error'
    foundCount   = 0
    updated      = @()
    remaining    = @()
    needsRestart = $false
    message      = ''
    logFile      = $LogFile
}
$record = $true

try {
    Write-Log ('=' * 70)
    Write-Log "Boshlandi. v$ScriptVersion | PowerShell $($PSVersionTable.PSVersion) | $env:COMPUTERNAME\$env:USERNAME"

    $cfg = Read-Config
    if ($Mode) { $cfg.mode = $Mode }
    if (@('report', 'auto') -notcontains $cfg.mode) {
        Write-Log "Noto'g'ri mode '$($cfg.mode)', 'report' ishlatiladi." -Level WARN
        $cfg.mode = 'report'
    }
    $result.mode = $cfg.mode
    Write-Log "Rejim: $($cfg.mode)"

    Rotate-Logs -Days ([int]$cfg.logRetentionDays)

    # ---- kunlik chegara: kuniga faqat 1 marta -------------------------------
    # Diqqat: mutex allaqachon qo'lda, ya'ni boshqa nusxa ishlamayapti.
    # Shuning uchun "running" holati faqat oldingi nusxa o'ldirilganini bildiradi.
    if (-not $Force -and (Test-Path $LastRunPath)) {
        $last = $null
        try { $last = Get-Content -Path $LastRunPath -Raw -Encoding UTF8 | ConvertFrom-Json } catch { }
        if ($last -and $last.date -eq $result.date) {
            $doneToday = @('ok', 'no-updates', 'partial', 'report') -contains $last.status

            if ($last.status -eq 'running') {
                $hb = 'noma''lum'
                $ph = 'noma''lum'
                if (Test-Path $StatePath) {
                    try {
                        $st = Get-Content -Path $StatePath -Raw -Encoding UTF8 | ConvertFrom-Json
                        if ($st.lastHeartbeat) { $hb = $st.lastHeartbeat }
                        if ($st.phase)         { $ph = $st.phase }
                    } catch { }
                }
                Write-Log ("Oldingi ishga tushirish tugallanmagan (bosqich: {0}, oxirgi belgi: {1}). Qaytadan boshlaymiz." -f $ph, $hb) -Level WARN
            }

            if ($doneToday) {
                Write-Log "Bugun allaqachon bajarilgan (status: $($last.status), $($last.finishedAt)). Chiqamiz."
                $result.status = 'skipped'
                $record = $false
                exit 0
            }
        }
    }

    $result.status = 'running'
    $result | ConvertTo-Json -Depth 5 | Set-Content -Path $LastRunPath -Encoding UTF8
    Set-RunState -Phase 'tekshirish'

    # ---- 1. tekshirish ------------------------------------------------------
    Write-Log 'Yangilanishlar tekshirilmoqda...'
    $found = @(Get-Upgradable)
    $result.foundCount = $found.Count

    if ($found.Count -eq 0) {
        Write-Log 'Yangilanish topilmadi. Hammasi yangi holatda.'
        $result.status = 'no-updates'
        $result.message = 'Yangilanish topilmadi'
        if ($cfg.notify -and $cfg.notifyNoUpdates) {
            Send-Toast -Title 'winget: yangilanish yo''q' -Body ('Barcha dasturlar yangi holatda. Tekshirildi: ' + (Get-Date).ToString('HH:mm'))
        }
        exit 0
    }

    Write-Log ("Topildi: {0} ta yangilanish" -f $found.Count)
    foreach ($p in $found) {
        Write-Log ("  * {0} [{1}] {2} -> {3}" -f $p.Name, $p.Id, $p.Version, $p.Available)
    }

    # ---- 2. report rejimi ---------------------------------------------------
    if ($cfg.mode -eq 'report') {
        Write-Log 'Report rejimi: hech narsa o''rnatilmadi.'
        $result.status = 'report'
        $result.remaining = @($found | ForEach-Object { "$($_.Id) $($_.Version) -> $($_.Available)" })
        $result.message = ('{0} ta yangilanish kutmoqda' -f $found.Count)
        if ($cfg.notify) {
            Send-Toast -Title ('winget: {0} ta yangilanish bor' -f $found.Count) -Body (Format-PkgList -Packages $found)
        }
        exit 0
    }

    # ---- 3. auto: aynan "winget upgrade --all" ------------------------------
    $timeout = [int]$cfg.timeoutMinutes * 60
    if ($timeout -lt 300) { $timeout = 300 }

    $wgArgs = @(
        'upgrade', '--all',
        '--include-unknown',
        '--accept-package-agreements', '--accept-source-agreements',
        '--disable-interactivity'
    )
    if ($cfg.silent) { $wgArgs += '--silent' }

    Write-Log ("Bajarilmoqda: winget " + ($wgArgs -join ' '))
    Set-RunState -Phase 'winget upgrade --all'
    $res = Invoke-Winget -Arguments $wgArgs -TimeoutSec $timeout

    if ($res.Output) {
        foreach ($l in ($res.Output -split "`r?`n")) {
            if ($l -match '\S') { Write-Log ("  | " + $l.TrimEnd()) }
        }
    }
    if ($res.Output -match '(?i)restart|reboot|перезагруз|перезапуск') {
        $result.needsRestart = $true
    }

    if ($res.TimedOut) {
        Write-Log ("TIMEOUT: {0} daqiqa - jarayon daraxti to'xtatildi" -f $cfg.timeoutMinutes) -Level ERROR
        $result.status = 'error'
        $result.message = 'winget upgrade --all timeout'
        if ($cfg.notify) { Send-Toast -Title 'winget: timeout' -Body 'Yangilash belgilangan vaqtda tugamadi.' }
        exit 0
    }

    # ---- 4. qayta tekshirish ------------------------------------------------
    Write-Log 'Qayta tekshirilmoqda...'
    Set-RunState -Phase 'qayta tekshirish'
    $after = @()
    $rescanOk = $true
    try {
        $after = @(Get-Upgradable)
    } catch {
        $rescanOk = $false
        Write-Log ("Qayta tekshirish amalga oshmadi: {0}" -f $_.Exception.Message) -Level WARN
    }

    $afterIds  = @($after | ForEach-Object { $_.Id })
    $updated   = @($found | Where-Object { $afterIds -notcontains $_.Id })

    $result.updated   = @($updated | ForEach-Object { "$($_.Id) $($_.Version) -> $($_.Available)" })
    $result.remaining = @($after | ForEach-Object { "$($_.Id) $($_.Version) -> $($_.Available)" })

    if (-not $rescanOk) {
        $result.status = 'partial'
    } elseif ($after.Count -eq 0 -and $res.ExitCode -eq 0) {
        $result.status = 'ok'
    } else {
        $result.status = 'partial'
    }

    $result.message = ('{0} ta yangilandi, {1} ta qoldi' -f $updated.Count, $after.Count)
    if (-not $rescanOk) { $result.message += ' (qayta tekshirish amalga oshmadi)' }
    Write-Log ("Natija: {0}" -f $result.message)

    if ($after.Count -gt 0) {
        Write-Log 'Qolgan paketlar (winget ularni yangilay olmadi - odatda scope/manifest nomuvofiqligi):' -Level WARN
        foreach ($p in $after) { Write-Log ("  ? {0} [{1}] {2} -> {3}" -f $p.Name, $p.Id, $p.Version, $p.Available) -Level WARN }
        Write-Log 'Maslahat: bu paketlarni ilovaning o''zidan yangilang yoki "winget pin add --id <Id>" bilan ro''yxatdan chiqaring.'
    }
    if ($result.needsRestart) { Write-Log 'Diqqat: ba''zi yangilanishlar uchun qayta ishga tushirish kerak.' -Level WARN }

    # ---- 5. toast -----------------------------------------------------------
    if ($cfg.notify) {
        if ($result.status -eq 'ok') {
            $body = ('{0} ta paket yangilandi.' -f $updated.Count)
            if ($result.needsRestart) { $body += ' Restart kerak.' }
            Send-Toast -Title 'winget: yangilash tugadi' -Body $body
        } else {
            $body = ('{0} ta yangilandi, {1} ta qoldi' -f $updated.Count, $after.Count)
            if ($after.Count -gt 0) { $body += ' (' + (Format-PkgList -Packages $after -Max 2) + ')' }
            Send-Toast -Title 'winget: qismiy bajarildi' -Body $body
        }
    }
}
catch {
    $result.status = 'error'
    $result.message = $_.Exception.Message
    Write-Log ("XATO: {0}" -f $_.Exception.Message) -Level ERROR
    Write-Log ("Stack: {0}" -f $_.ScriptStackTrace) -Level ERROR
    if ($record -and $cfg -and $cfg.notify) {
        try { Send-Toast -Title 'winget: xato' -Body $_.Exception.Message } catch { }
    }
}
finally {
    if ($record) {
        $result.finishedAt = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
        try {
            $result | ConvertTo-Json -Depth 5 | Set-Content -Path $LastRunPath -Encoding UTF8
        } catch { }
        # run-state.json ni "tugadi" deb belgilaymiz (o'chirmaymiz - diagnostika uchun)
        try {
            $done = [ordered]@{
                ProcessId     = $PID
                startedAt     = $script:RunStartedAt
                phase         = 'tugadi'
                lastHeartbeat = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
                status        = $result.status
            }
            $done | ConvertTo-Json -Depth 3 | Set-Content -Path $StatePath -Encoding UTF8
        } catch { }
    }
    try { $mutex.ReleaseMutex() } catch { }
    try { $mutex.Dispose() } catch { }
    Write-Log "Tugadi (status: $($result.status))."
}
