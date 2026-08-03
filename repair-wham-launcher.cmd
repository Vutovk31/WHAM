@echo off
setlocal EnableExtensions

powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "$ErrorActionPreference='Stop';$d=Join-Path $env:LOCALAPPDATA 'Programs\WHAM Quick Replies';$s=Join-Path $d 'start-wham.cmd';$v=Join-Path $d 'start-wham-hidden.vbs';if(-not(Test-Path -LiteralPath $s -PathType Leaf)){throw ('WHAM Quick Replies is not installed correctly. Missing file: '+$s)};$q=[char]34;$p=[char]37;$l=@('Option Explicit','Dim shell, fso, baseDir, startFile, commandProcessor, commandLine','Set shell = CreateObject('+$q+'WScript.Shell'+$q+')','Set fso = CreateObject('+$q+'Scripting.FileSystemObject'+$q+')','baseDir = fso.GetParentFolderName(WScript.ScriptFullName)','startFile = fso.BuildPath(baseDir, '+$q+'start-wham.cmd'+$q+')','','If Not fso.FileExists(startFile) Then','    MsgBox '+$q+'WHAM start file was not found:'+$q+' & vbCrLf & startFile, 16, '+$q+'WHAM Quick Replies'+$q,'    WScript.Quit 1','End If','','commandProcessor = shell.ExpandEnvironmentStrings('+$q+$p+'ComSpec'+$p+$q+')','If Len(commandProcessor) = 0 Or Not fso.FileExists(commandProcessor) Then','    commandProcessor = fso.BuildPath(shell.ExpandEnvironmentStrings('+$q+$p+'SystemRoot'+$p+$q+'), '+$q+'System32\cmd.exe'+$q+')','End If','','If Not fso.FileExists(commandProcessor) Then','    MsgBox '+$q+'Windows command processor was not found:'+$q+' & vbCrLf & commandProcessor, 16, '+$q+'WHAM Quick Replies'+$q,'    WScript.Quit 2','End If','','shell.CurrentDirectory = baseDir','commandLine = Chr(34) & commandProcessor & Chr(34) & '+$q+' /d /c '+$q+' & Chr(34) & startFile & Chr(34)','shell.Run commandLine, 0, False');[IO.File]::WriteAllLines($v,$l,(New-Object Text.UTF8Encoding($false)));$w=Join-Path $env:SystemRoot 'System32\wscript.exe';if(-not(Test-Path -LiteralPath $w -PathType Leaf)){throw ('Windows Script Host was not found: '+$w)};Start-Process -FilePath $w -ArgumentList ([char]34+$v+[char]34) -WorkingDirectory $d"
if errorlevel 1 (
    echo.
    echo WHAM launcher repair failed.
    echo Reinstall WHAM from a fully extracted archive and try again.
    pause
    exit /b 1
)

echo WHAM launcher repaired and started.
timeout /t 2 /nobreak >nul
exit /b 0
