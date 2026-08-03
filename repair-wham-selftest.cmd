@echo off
setlocal EnableExtensions
cd /d "%~dp0"

if not exist "%~dp0repair-wham-selftest.ps1" (
    echo repair-wham-selftest.ps1 was not found next to this file.
    echo Download both repair files into the extracted WHAM folder.
    pause
    exit /b 1
)

powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File "%~dp0repair-wham-selftest.ps1"
set "WHAM_EXIT=%ERRORLEVEL%"
if not "%WHAM_EXIT%"=="0" (
    echo.
    echo WHAM core repair failed.
    echo Send this screen and WHAM-errors.log to the developer.
    pause
)
exit /b %WHAM_EXIT%
