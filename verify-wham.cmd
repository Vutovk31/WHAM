@echo off
setlocal EnableExtensions
cd /d "%~dp0"

set "WHAM_SCRIPT=%~dp0WHAM.QuickReplies.ps1"
set "WHAM_MACROS=%~dp0macros.json"
set "WHAM_PASTE_TEST=%~dp0tests\Test-NotepadPaste.ps1"

where powershell.exe >nul 2>nul
if errorlevel 1 (
    echo FAILED: Windows PowerShell was not found.
    echo WHAM requires the built-in Windows PowerShell 5.1.
    goto failed
)

if not exist "%WHAM_SCRIPT%" (
    echo FAILED: WHAM.QuickReplies.ps1 was not found.
    goto failed
)
if not exist "%WHAM_MACROS%" (
    echo FAILED: macros.json was not found.
    goto failed
)
if not exist "%WHAM_PASTE_TEST%" (
    echo FAILED: tests\Test-NotepadPaste.ps1 was not found.
    goto failed
)

echo [1/2] Checking macros, WinForms and global hotkey registration...
powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File "%WHAM_SCRIPT%" -MacrosPath "%WHAM_MACROS%" -SelfTest
if errorlevel 1 goto failed

echo.
echo [2/2] Checking Unicode multiline paste in Windows Notepad...
powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File "%WHAM_PASTE_TEST%"
if errorlevel 1 goto failed

echo.
echo WHAM VERIFICATION PASSED.
echo Confirmed: macro storage, template expansion, global hotkey registration,
echo WinForms startup and Unicode multiline paste into Notepad.
echo.
pause
exit /b 0

:failed
echo.
echo WHAM VERIFICATION FAILED.
echo Copy the complete text from this window when reporting the problem.
echo.
pause
exit /b 1
