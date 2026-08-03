@echo off
setlocal EnableExtensions
set "WHAM_UNINSTALLER=%~f0"

powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -Command "$raw=[IO.File]::ReadAllText($env:WHAM_UNINSTALLER); $marker='#<WHAM-POWERSHELL>'; $index=$raw.LastIndexOf($marker); if($index -lt 0){throw 'Uninstaller payload not found.'}; Invoke-Expression $raw.Substring($index+$marker.Length)"
set "WHAM_EXIT=%ERRORLEVEL%"
if not "%WHAM_EXIT%"=="0" (
    echo.
    echo WHAM uninstall failed.
    pause
)
exit /b %WHAM_EXIT%

#<WHAM-POWERSHELL>
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms

$installDir = Join-Path $env:LOCALAPPDATA 'Programs\WHAM Quick Replies'
$startMenuDir = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\WHAM Quick Replies'
$startupShortcut = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\Startup\WHAM Quick Replies.lnk'
$shell = New-Object -ComObject WScript.Shell
$desktopShortcut = Join-Path ([string]$shell.SpecialFolders.Item('Desktop')) 'WHAM Quick Replies.lnk'

$answer = [System.Windows.Forms.MessageBox]::Show(
    'Удалить WHAM Quick Replies с этого компьютера? Перед удалением macros.json будет сохранён в папку Документы.',
    'Удаление WHAM Quick Replies',
    [System.Windows.Forms.MessageBoxButtons]::YesNo,
    [System.Windows.Forms.MessageBoxIcon]::Question
)
if ($answer -ne [System.Windows.Forms.DialogResult]::Yes) { exit 0 }

$backupPath = $null
$macrosPath = Join-Path $installDir 'macros.json'
if (Test-Path -LiteralPath $macrosPath -PathType Leaf) {
    $backupDir = Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'WHAM Backups'
    New-Item -ItemType Directory -Path $backupDir -Force | Out-Null
    $backupPath = Join-Path $backupDir ("WHAM-macros-{0}.json" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
    Copy-Item -LiteralPath $macrosPath -Destination $backupPath -Force
}

$selfPid = $PID
Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
    Where-Object {
        $_.ProcessId -ne $selfPid -and
        ($_.Name -ieq 'powershell.exe' -or $_.Name -ieq 'pwsh.exe') -and
        $_.CommandLine -and
        (
            $_.CommandLine.IndexOf((Join-Path $installDir 'WHAM.QuickReplies.ps1'), [StringComparison]::OrdinalIgnoreCase) -ge 0 -or
            $_.CommandLine.IndexOf('WHAM_SCRIPT', [StringComparison]::OrdinalIgnoreCase) -ge 0
        )
    } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }

Remove-Item -LiteralPath $startupShortcut -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath $desktopShortcut -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath $startMenuDir -Recurse -Force -ErrorAction SilentlyContinue

if (Test-Path -LiteralPath $installDir -PathType Container) {
    $cleanupPath = Join-Path $env:TEMP ("WHAM-remove-{0}.cmd" -f [Guid]::NewGuid().ToString('N'))
    $cleanup = @"
@echo off
timeout /t 3 /nobreak >nul
rmdir /s /q "$installDir"
del /q "%~f0"
"@
    [IO.File]::WriteAllText($cleanupPath, $cleanup, [Text.Encoding]::ASCII)
    Start-Process -FilePath 'cmd.exe' -ArgumentList '/c', ('"{0}"' -f $cleanupPath) -WindowStyle Hidden
}

$message = 'WHAM Quick Replies удалён. Ярлыки и автозапуск отключены.'
if ($backupPath) {
    $message += "`r`n`r`nРезервная копия макросов:`r`n$backupPath"
}
[System.Windows.Forms.MessageBox]::Show(
    $message,
    'Удаление WHAM Quick Replies',
    [System.Windows.Forms.MessageBoxButtons]::OK,
    [System.Windows.Forms.MessageBoxIcon]::Information
) | Out-Null
