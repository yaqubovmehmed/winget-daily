# winget-daily

Automated daily Windows app updates with `winget`. One scheduled task, no terminal, no manual work.

Once a day — a few minutes after you log in — it checks for updates and, if any exist, runs exactly what you would type by hand:

```
winget upgrade --all
```

Then it writes a log and shows a Windows toast notification.

---

## What it does

| Step | Action |
|---|---|
| 1 | Wait for logon + N minutes (default **3**) |
| 2 | Run `winget upgrade --include-unknown` to scan |
| 3 | No updates → notify and exit (next check tomorrow) |
| 4 | Updates found → run `winget upgrade --all` |
| 5 | Re-scan to see what actually got updated |
| 6 | Write `logs\YYYY-MM-DD.log`, update `last-run.json`, show a toast |

Safety features:

- **One run per day** — a second trigger on the same day is skipped.
- **Single instance** — a named mutex prevents overlapping runs.
- **Retry on failure** — Task Scheduler retries 3 times, 10 minutes apart.
- **Crash-resistant** — a heartbeat file records the last phase, so a killed run is detected and resumed next time instead of blocking the whole day.
- **No hardcoded paths** — everything is relative to the script folder.

---

## Requirements

- Windows 10 or Windows 11
- PowerShell 5.1 (built in)
- `winget` — [App Installer](https://apps.microsoft.com/detail/9nblggh4nns1). Preinstalled on Windows 11.
- Administrator rights **once**, to register the scheduled task

---

## Install

### Option A — ZIP (easiest)

1. Download and extract the ZIP.
2. Double-click **`install.cmd`**.
3. Approve the UAC prompt.
4. Done.

The files are copied to `%LOCALAPPDATA%\winget-daily`, so you can delete the extracted folder afterwards.

> Windows SmartScreen may warn about the unsigned script. Choose **More info → Run anyway**.

### Option B — from source

```powershell
git clone https://github.com/<owner>/winget-daily.git
cd winget-daily
powershell -ExecutionPolicy Bypass -File install-task.ps1
```

Run that from an **elevated** PowerShell (Run as administrator).

### Custom delay

```powershell
powershell -ExecutionPolicy Bypass -File install-task.ps1 -DelayMinutes 10
```

---

## Configuration

Edit `%LOCALAPPDATA%\winget-daily\config.json`. Changes apply on the next run — no need to re-register the task.

```json
{
  "mode": "auto",
  "timeoutMinutes": 60,
  "silent": true,
  "notify": true,
  "notifyNoUpdates": true,
  "logRetentionDays": 30
}
```

| Key | Meaning |
|---|---|
| `mode` | `auto` = install updates. `report` = only list them, install nothing |
| `timeoutMinutes` | Max time for `winget upgrade --all` before the process tree is killed |
| `silent` | Pass `--silent` to winget (no installer windows) |
| `notify` | Show Windows toast notifications |
| `notifyNoUpdates` | Also notify when there is nothing to update |
| `logRetentionDays` | Delete log files older than this |

> Tip: start with `"mode": "report"` for a few days to see what it would do, then switch to `auto`.

---

## Logs and status

```
%LOCALAPPDATA%\winget-daily\
├── winget-daily.ps1     main script
├── install-task.ps1     registers / re-registers the task
├── config.json          settings
├── last-run.json        result of the last run
├── run-state.json       heartbeat of the current/last run
└── logs\
    └── 2026-11-25.log   daily log
```

Status values in `last-run.json`: `ok`, `no-updates`, `partial`, `report`, `error`, `running`, `skipped`.

---

## Manual run

```powershell
# what would happen, without installing anything
powershell -File winget-daily.ps1 -Force -Mode report

# run now, for real
powershell -File winget-daily.ps1 -Force

# start through Task Scheduler (same as the daily trigger)
Start-ScheduledTask -TaskName WingetDailyUpdate
```

`-Force` bypasses the once-per-day guard.

---

## Excluding a package

Use winget's own mechanism — no config needed:

```powershell
winget pin add --id Some.Package
winget pin remove --id Some.Package
```

---

## Uninstall

```powershell
Unregister-ScheduledTask -TaskName WingetDailyUpdate -Confirm:$false
Remove-Item "$env:LOCALAPPDATA\winget-daily" -Recurse -Force
```

---

## Known limitations

- **Tested on Windows 11 with PowerShell 5.1 only.**
- Some packages cannot be upgraded by winget at all — for example when the installed copy is user-scope but the manifest declares `Scope: machine`. In that case `winget upgrade --all` silently skips them, with or without this tool. Update those through the app itself.
- A package that is currently running may block its own update (e.g. MSIX apps in use).
- Toasts require an interactive user session.

---

## Qisqa qo'llanma (o'zbekcha)

1. ZIP'ni yuklab oling va oching.
2. `install.cmd` ni ikki marta bosing.
3. UAC oynasida **Ha** ni tanlang.
4. Tamom — ertadan boshlab har kuni noutbuk yongach 3 daqiqada o'zi tekshiradi va yangilaydi.

Sozlash: `%LOCALAPPDATA%\winget-daily\config.json`
Loglar: `%LOCALAPPDATA%\winget-daily\logs\`
O'chirish: `Unregister-ScheduledTask -TaskName WingetDailyUpdate`

---

## License

MIT — see [LICENSE](LICENSE).
