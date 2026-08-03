@echo off
setlocal EnableExtensions

set "WHAM_TARGET=%~dp0start-wham.cmd"
set "WHAM_WORKDIR=%~dp0"
set "WHAM_LINK=%APPDATA%\Microsoft\Windows\Start Menu\Programs\Startup\WHAM Quick Replies.lnk"

if /I "%~1"=="--enable" goto enable
if /I "%~1"=="--disable" goto disable
if /I "%~1"=="--status" goto status

if exist "%WHAM_LINK%" (
    goto disable
) else (
    goto enable
)

:enable
if not exist "%WHAM_TARGET%" (
    echo WHAM startup file was not found:
    echo %WHAM_TARGET%
    echo Keep toggle-autostart.cmd next to start-wham.cmd.
    exit /b 1
)

powershell.exe -NoProfile -ExecutionPolicy Bypass -Command ^
  "$ErrorActionPreference='Stop'; $shell=New-Object -ComObject WScript.Shell; $shortcut=$shell.CreateShortcut($env:WHAM_LINK); $shortcut.TargetPath=$env:WHAM_TARGET; $shortcut.WorkingDirectory=$env:WHAM_WORKDIR; $shortcut.Description='Start WHAM Quick Replies with Windows'; $shortcut.IconLocation='shell32.dll,167'; $shortcut.Save()"
if errorlevel 1 (
    echo Could not enable WHAM autostart.
    exit /b 1
)
if not exist "%WHAM_LINK%" (
    echo Autostart shortcut was not created.
    exit /b 1
)

echo WHAM Quick Replies autostart is ENABLED for the current Windows user.
echo No administrator rights are required.
exit /b 0

:disable
if exist "%WHAM_LINK%" del /F /Q "%WHAM_LINK%"
if exist "%WHAM_LINK%" (
    echo Could not disable WHAM autostart.
    exit /b 1
)

echo WHAM Quick Replies autostart is DISABLED for the current Windows user.
exit /b 0

:status
if exist "%WHAM_LINK%" (
    echo WHAM Quick Replies autostart is ENABLED.
    exit /b 0
)

echo WHAM Quick Replies autostart is DISABLED.
exit /b 1
