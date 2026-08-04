@echo off
setlocal EnableExtensions
cd /d "%~dp0"

set "WHAM_SCRIPT=%~dp0WHAM.QuickReplies.ps1"
set "WHAM_POWERSHELL=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"

if not exist "%WHAM_POWERSHELL%" set "WHAM_POWERSHELL=powershell.exe"

if not exist "%WHAM_SCRIPT%" (
    echo WHAM.QuickReplies.ps1 was not found.
    echo Fully extract the WHAM archive and run this file again.
    pause
    exit /b 1
)

rem Windows PowerShell 5.1 needs a UTF-8 BOM for reliable Cyrillic text.
"%WHAM_POWERSHELL%" -NoProfile -ExecutionPolicy Bypass -Command ^
  "$p=$env:WHAM_SCRIPT;$b=[IO.File]::ReadAllBytes($p);if($b.Length-lt 3-or$b[0]-ne239-or$b[1]-ne187-or$b[2]-ne191){$t=[Text.UTF8Encoding]::new($false,$true).GetString($b);[IO.File]::WriteAllText($p,$t,[Text.UTF8Encoding]::new($true))}"
if errorlevel 1 (
    echo WHAM could not prepare the PowerShell file.
    pause
    exit /b 1
)

rem Normal startup no longer depends on the optional self-test.
start "WHAM Quick Replies" "%WHAM_POWERSHELL%" -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File "%WHAM_SCRIPT%"
exit /b 0
