@echo off
setlocal EnableExtensions
cd /d "%~dp0"

set "WHAM_SCRIPT=%~dp0WHAM.QuickReplies.ps1"
set "WHAM_LOG=%~dp0WHAM-errors.log"
set "WHAM_STATUS=%~dp0WHAM-status.txt"

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

rem Stop all prior WHAM PowerShell instances before registering global hotkeys again.
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

rem The application intentionally has no permanent main window. It runs in the tray.
start "" powershell.exe -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -STA -File "%WHAM_SCRIPT%"

rem Confirm that the hidden tray process survived startup and write a readable status file.
timeout /t 4 /nobreak >nul
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command ^
  "$ErrorActionPreference='Stop'; $p=$env:WHAM_SCRIPT; $status=$env:WHAM_STATUS; $log=$env:WHAM_LOG; $processes=@(Get-CimInstance Win32_Process | Where-Object { ($_.Name -ieq 'powershell.exe' -or $_.Name -ieq 'pwsh.exe') -and $_.CommandLine -and $_.CommandLine.IndexOf($p,[StringComparison]::OrdinalIgnoreCase) -ge 0 }); if($processes.Count -eq 0){$line='['+(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')+'] WHAM exited during startup verification.'; Add-Content -LiteralPath $log -Value $line -Encoding UTF8; Set-Content -LiteralPath $status -Value @('STATUS: STOPPED','TIME: '+(Get-Date -Format 'yyyy-MM-dd HH:mm:ss'),'SCRIPT: '+$p,'LOG: '+$log) -Encoding UTF8; exit 1}; $macrosPath=Join-Path (Split-Path -Parent $p) 'macros.json'; $macros=@(Get-Content -LiteralPath $macrosPath -Raw -Encoding UTF8 | ConvertFrom-Json); $hotkeys=@($macros | ForEach-Object { [string]$_.hotkey }); Set-Content -LiteralPath $status -Value @('STATUS: RUNNING','TIME: '+(Get-Date -Format 'yyyy-MM-dd HH:mm:ss'),'PID: '+(($processes | Select-Object -ExpandProperty ProcessId) -join ', '),'MACROS: '+$macros.Count,'HOTKEYS: '+($hotkeys -join ', '),'SCRIPT: '+$p) -Encoding UTF8"
if errorlevel 1 (
    echo.
    echo WHAM closed unexpectedly during startup.
    echo Status: %WHAM_STATUS%
    echo Errors: %WHAM_LOG%
    echo.
    echo Send both files to the developer.
    pause
    exit /b 1
)

exit /b 0
