@echo off
setlocal EnableExtensions
cd /d "%~dp0"

set "WHAM_SCRIPT=%~dp0WHAM.QuickReplies.ps1"
set "WHAM_LOG=%~dp0WHAM-errors.log"

if not exist "%WHAM_SCRIPT%" (
    echo WHAM.QuickReplies.ps1 was not found:
    echo %WHAM_SCRIPT%
    echo.
    echo Reinstall WHAM from the fully extracted archive.
    pause
    exit /b 1
)

rem Windows PowerShell 5.1 requires UTF-8 BOM for scripts containing Cyrillic text.
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command ^
  "$ErrorActionPreference='Stop'; $p=$env:WHAM_SCRIPT; $bytes=[IO.File]::ReadAllBytes($p); $hasBom=($bytes.Length -ge 3 -and $bytes[0] -eq 239 -and $bytes[1] -eq 187 -and $bytes[2] -eq 191); if(-not $hasBom){$utf8=New-Object Text.UTF8Encoding($false,$true); $text=$utf8.GetString($bytes); [IO.File]::WriteAllText($p,$text,(New-Object Text.UTF8Encoding($true)))}"
if errorlevel 1 (
    echo.
    echo WHAM could not repair the PowerShell file encoding.
    echo File: %WHAM_SCRIPT%
    pause
    exit /b 1
)

rem Previous launchers used -Command with an environment variable, so the installer
rem could not identify and stop old hidden WHAM processes. Stop all prior WHAM
rem PowerShell instances owned by this user before registering global hotkeys again.
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command ^
  "$ErrorActionPreference='SilentlyContinue'; $self=$PID; $p=$env:WHAM_SCRIPT; Get-CimInstance Win32_Process | Where-Object { $_.ProcessId -ne $self -and ($_.Name -ieq 'powershell.exe' -or $_.Name -ieq 'pwsh.exe') -and $_.CommandLine -and ($_.CommandLine.IndexOf($p,[StringComparison]::OrdinalIgnoreCase) -ge 0 -or $_.CommandLine.IndexOf('WHAM_SCRIPT',[StringComparison]::OrdinalIgnoreCase) -ge 0) } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }"

timeout /t 1 /nobreak >nul

rem Validate the installed script and macros before starting the hidden tray process.
powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File "%WHAM_SCRIPT%" -SelfTest >nul 2>>"%WHAM_LOG%"
if errorlevel 1 (
    echo.
    echo WHAM self-test failed. See:
    echo %WHAM_LOG%
    pause
    exit /b 1
)

rem -File keeps the real script path in the process command line, allowing future
rem installers and launches to stop the correct instance before updating hotkeys.
start "" powershell.exe -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -STA -File "%WHAM_SCRIPT%"
exit /b 0
