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

rem Windows PowerShell 5.1 reads UTF-8 scripts without BOM as the legacy ANSI code page.
rem Normalize the application script to UTF-8 with BOM before PowerShell parses it.
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command ^
  "$ErrorActionPreference='Stop'; $p=$env:WHAM_SCRIPT; $bytes=[IO.File]::ReadAllBytes($p); $hasBom=($bytes.Length -ge 3 -and $bytes[0] -eq 239 -and $bytes[1] -eq 187 -and $bytes[2] -eq 191); if(-not $hasBom){$utf8=New-Object Text.UTF8Encoding($false,$true); $text=$utf8.GetString($bytes); $utf8Bom=New-Object Text.UTF8Encoding($true); [IO.File]::WriteAllText($p,$text,$utf8Bom)}"
if errorlevel 1 (
    echo.
    echo WHAM could not repair the PowerShell file encoding.
    echo File: %WHAM_SCRIPT%
    pause
    exit /b 1
)

start "" powershell.exe -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -STA -Command ^
  "$ErrorActionPreference='Stop'; $p=$env:WHAM_SCRIPT; $log=$env:WHAM_LOG; try { & $p } catch { Add-Type -AssemblyName System.Windows.Forms; $m=$_.Exception.ToString(); try { [IO.File]::AppendAllText($log, ('['+(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')+'] '+$m+[Environment]::NewLine), [Text.Encoding]::UTF8) } catch {}; [Windows.Forms.MessageBox]::Show($m, 'WHAM Quick Replies - startup error', 'OK', 'Error') | Out-Null; exit 1 }"

exit /b 0
