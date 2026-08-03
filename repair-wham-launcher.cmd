@echo off
setlocal EnableExtensions
set "WHAM_DIR=%LOCALAPPDATA%\Programs\WHAM Quick Replies"
set "WHAM_START=%WHAM_DIR%\start-wham.cmd"
set "WHAM_VBS=%WHAM_DIR%\start-wham-hidden.vbs"

if not exist "%WHAM_START%" (
    echo WHAM Quick Replies is not installed correctly.
    echo Missing file: %WHAM_START%
    echo Reinstall WHAM from the fully extracted archive.
    pause
    exit /b 1
)

powershell.exe -NoProfile -ExecutionPolicy Bypass -Command ^
  "$ErrorActionPreference='Stop'; $path=$env:WHAM_VBS; $content=@'
Option Explicit
Dim shell, fso, baseDir, startFile, commandProcessor, commandLine
Set shell = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")
baseDir = fso.GetParentFolderName(WScript.ScriptFullName)
startFile = fso.BuildPath(baseDir, "start-wham.cmd")

If Not fso.FileExists(startFile) Then
    MsgBox "WHAM start file was not found:" & vbCrLf & startFile, 16, "WHAM Quick Replies"
    WScript.Quit 1
End If

commandProcessor = shell.ExpandEnvironmentStrings("%ComSpec%")
If Len(commandProcessor) = 0 Or Not fso.FileExists(commandProcessor) Then
    commandProcessor = fso.BuildPath(shell.ExpandEnvironmentStrings("%SystemRoot%"), "System32\cmd.exe")
End If

If Not fso.FileExists(commandProcessor) Then
    MsgBox "Windows command processor was not found:" & vbCrLf & commandProcessor, 16, "WHAM Quick Replies"
    WScript.Quit 2
End If

shell.CurrentDirectory = baseDir
commandLine = Chr(34) & commandProcessor & Chr(34) & " /d /c " & Chr(34) & startFile & Chr(34)
shell.Run commandLine, 0, False
'@; [IO.File]::WriteAllText($path,$content,(New-Object Text.UTF8Encoding($false)))"

if errorlevel 1 (
    echo Failed to repair the WHAM hidden launcher.
    pause
    exit /b 1
)

"%SystemRoot%\System32\wscript.exe" "%WHAM_VBS%"
if errorlevel 1 (
    echo The launcher was repaired, but WHAM did not start.
    echo Try running: %WHAM_START%
    pause
    exit /b 1
)

echo WHAM launcher repaired and started.
timeout /t 2 /nobreak >nul
exit /b 0
