@echo off
setlocal EnableExtensions
cd /d "%~dp0"

set "WHAM_SCRIPT=%~dp0WHAM.QuickReplies.ps1"

if not exist "%WHAM_SCRIPT%" (
    echo WHAM.QuickReplies.ps1 was not found:
    echo %WHAM_SCRIPT%
    echo Reinstall WHAM from the fully extracted archive.
    pause
    exit /b 1
)

rem Repair the startup regression published in a1118d7. In PowerShell,
rem backslash is already literal, so Local\\ created an invalid mutex name.
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command ^
  "$ErrorActionPreference='Stop'; $p=$env:WHAM_SCRIPT; $c=[IO.File]::ReadAllText($p); $q=[char]39; $broken=$q+'Local\\WHAM.QuickReplies'+$q; $fixed=$q+'Local\WHAM.QuickReplies'+$q; if($c.Contains($broken)){Set-Content -LiteralPath $p -Value $c.Replace($broken,$fixed) -Encoding UTF8 -NoNewline}"
if errorlevel 1 (
    echo.
    echo WHAM startup repair failed.
    echo Try reinstalling WHAM into your user profile.
    pause
    exit /b 1
)

start "" powershell.exe -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -STA -File "%WHAM_SCRIPT%"
