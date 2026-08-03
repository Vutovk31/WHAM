@echo off
setlocal EnableExtensions
cd /d "%~dp0"

set "PATCH=%~dp0tools\Apply-HotkeyDropdownPatch.ps1"
set "APP=%~dp0WHAM.QuickReplies.ps1"
set "INSTALLER=%~dp0install-wham.cmd"

if not exist "%PATCH%" (
    echo Hotfix file was not found:
    echo %PATCH%
    pause
    exit /b 1
)
if not exist "%APP%" (
    echo WHAM application file was not found:
    echo %APP%
    pause
    exit /b 1
)

echo Applying WHAM hotkey editor repair...
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%PATCH%"
if errorlevel 1 (
    echo.
    echo Hotfix failed. No installation was started.
    pause
    exit /b 1
)

echo Verifying repaired WHAM core...
powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File "%APP%" -SelfTest
if errorlevel 1 (
    echo.
    echo WHAM verification failed. No installation was started.
    pause
    exit /b 1
)

if not exist "%INSTALLER%" (
    echo Installer was not found:
    echo %INSTALLER%
    pause
    exit /b 1
)

echo Installing repaired WHAM Quick Replies...
call "%INSTALLER%"
exit /b %ERRORLEVEL%
