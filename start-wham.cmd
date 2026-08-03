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

start "" powershell.exe -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -STA -Command ^
  "$ErrorActionPreference='Stop'; $p=$env:WHAM_SCRIPT; $log=$env:WHAM_LOG; try { & $p } catch { Add-Type -AssemblyName System.Windows.Forms; $m=$_.Exception.ToString(); try { [IO.File]::AppendAllText($log, ('['+(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')+'] '+$m+[Environment]::NewLine), [Text.Encoding]::UTF8) } catch {}; [Windows.Forms.MessageBox]::Show($m, 'WHAM Quick Replies - startup error', 'OK', 'Error') | Out-Null; exit 1 }"

exit /b 0
