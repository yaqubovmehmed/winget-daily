@echo off
setlocal EnableExtensions
title winget-daily setup

set "SRC=%~dp0"
set "DEST=%LOCALAPPDATA%\winget-daily"

rem ---------- admin huquqini tekshirish ----------
net session >nul 2>&1
if errorlevel 1 (
    echo.
    echo Administrator huquqi so'raladi. "Ha" tugmasini bosing...
    echo.
    powershell -NoProfile -ExecutionPolicy Bypass -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
    exit /b
)

echo ==================================================
echo    winget-daily - avtomatik kunlik yangilash
echo ==================================================
echo.

if /I "%SRC:~0,-1%"=="%DEST%" (
    echo Fayllar allaqachon o'z joyida - nusxalash shart emas.
) else (
    if not exist "%DEST%" mkdir "%DEST%" >nul 2>&1
    echo Fayllar nusxalanmoqda: %DEST%
    copy /Y "%SRC%winget-daily.ps1" "%DEST%\" >nul
    copy /Y "%SRC%install-task.ps1" "%DEST%\" >nul
    if not exist "%DEST%\config.json" copy /Y "%SRC%config.json" "%DEST%\" >nul
)

echo Internet belgisi olib tashlanmoqda (bloklanishning oldini oladi)...
powershell -NoProfile -ExecutionPolicy Bypass -Command "Get-ChildItem -LiteralPath '%DEST%' -Filter '*.ps1' -ErrorAction SilentlyContinue | Unblock-File -ErrorAction SilentlyContinue" >nul 2>&1

echo Task ro'yxatdan o'tkazilmoqda...
echo.
powershell -NoProfile -ExecutionPolicy Bypass -File "%DEST%\install-task.ps1"
set "RC=%ERRORLEVEL%"

echo.
if "%RC%"=="0" (
    echo --------------------------------------------------
    echo   TAYYOR.
    echo --------------------------------------------------
    echo   Endi har kuni noutbuk yonganda:
    echo     logon + 3 daqiqa -^> tekshiradi
    echo     yangilanish bo'lsa -^> winget upgrade --all
    echo     natija -^> log + Windows toast
    echo.
    echo   Sozlash:  %DEST%\config.json
    echo   Loglar:   %DEST%\logs\
    echo   O'chirish: Unregister-ScheduledTask -TaskName WingetDailyUpdate
) else (
    echo --------------------------------------------------
    echo   XATO: o'rnatish bajarilmadi ^(kod %RC%^).
    echo   Administrator huquqi bilan qayta urinib ko'ring.
    echo --------------------------------------------------
)

echo.
pause
endlocal
