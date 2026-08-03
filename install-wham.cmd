@echo off
setlocal EnableExtensions
set "WHAM_INSTALLER=%~f0"

powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "$raw=[IO.File]::ReadAllText($env:WHAM_INSTALLER); $marker='#<WHAM-POWERSHELL>'; $index=$raw.LastIndexOf($marker); if($index -lt 0){throw 'Installer payload not found.'}; Invoke-Expression $raw.Substring($index+$marker.Length)"
set "WHAM_EXIT=%ERRORLEVEL%"
if not "%WHAM_EXIT%"=="0" (
    echo.
    echo WHAM installation failed.
    pause
)
exit /b %WHAM_EXIT%

#<WHAM-POWERSHELL>
$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName System.Windows.Forms

$sourceRoot = Split-Path -Parent $env:WHAM_INSTALLER
$installDir = Join-Path $env:LOCALAPPDATA 'Programs\WHAM Quick Replies'
$startMenuDir = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\WHAM Quick Replies'
$startupShortcut = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\Startup\WHAM Quick Replies.lnk'
$shell = New-Object -ComObject WScript.Shell
$desktopDir = [string]$shell.SpecialFolders.Item('Desktop')

$requiredFiles = @(
    'WHAM.QuickReplies.ps1',
    'start-wham.cmd',
    'toggle-autostart.cmd',
    'macros.json'
)

foreach ($name in $requiredFiles) {
    $sourcePath = Join-Path $sourceRoot $name
    if (-not (Test-Path -LiteralPath $sourcePath -PathType Leaf)) {
        throw "Required installer file is missing: $sourcePath"
    }
}

New-Item -ItemType Directory -Path $installDir -Force | Out-Null
New-Item -ItemType Directory -Path $startMenuDir -Force | Out-Null

# Stop only an already installed WHAM instance so program files can be updated safely.
Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.CommandLine -and $_.CommandLine.IndexOf((Join-Path $installDir 'WHAM.QuickReplies.ps1'), [StringComparison]::OrdinalIgnoreCase) -ge 0 } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }

foreach ($name in @('WHAM.QuickReplies.ps1', 'start-wham.cmd', 'toggle-autostart.cmd')) {
    Copy-Item -LiteralPath (Join-Path $sourceRoot $name) -Destination (Join-Path $installDir $name) -Force
}

$installedMacros = Join-Path $installDir 'macros.json'
if (-not (Test-Path -LiteralPath $installedMacros -PathType Leaf)) {
    Copy-Item -LiteralPath (Join-Path $sourceRoot 'macros.json') -Destination $installedMacros
}

$readmeSource = Join-Path $sourceRoot 'README.md'
if (Test-Path -LiteralPath $readmeSource -PathType Leaf) {
    Copy-Item -LiteralPath $readmeSource -Destination (Join-Path $installDir 'README.md') -Force
}

$uninstallScript = @'
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms

$installDir = Join-Path $env:LOCALAPPDATA 'Programs\WHAM Quick Replies'
$startMenuDir = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\WHAM Quick Replies'
$startupShortcut = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\Startup\WHAM Quick Replies.lnk'
$shell = New-Object -ComObject WScript.Shell
$desktopShortcut = Join-Path ([string]$shell.SpecialFolders.Item('Desktop')) 'WHAM Quick Replies.lnk'

$answer = [System.Windows.Forms.MessageBox]::Show(
    'Удалить WHAM Quick Replies? Перед удалением macros.json будет сохранён в папку Документы.',
    'WHAM Quick Replies',
    'YesNo',
    'Question'
)
if ($answer -ne [System.Windows.Forms.DialogResult]::Yes) { exit 0 }

$backupPath = $null
$macrosPath = Join-Path $installDir 'macros.json'
if (Test-Path -LiteralPath $macrosPath -PathType Leaf) {
    $documents = [Environment]::GetFolderPath('MyDocuments')
    $backupPath = Join-Path $documents ("WHAM-macros-backup-{0}.json" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
    Copy-Item -LiteralPath $macrosPath -Destination $backupPath -Force
}

Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
    Where-Object {
        $_.ProcessId -ne $PID -and
        $_.CommandLine -and
        $_.CommandLine.IndexOf((Join-Path $installDir 'WHAM.QuickReplies.ps1'), [StringComparison]::OrdinalIgnoreCase) -ge 0
    } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }

Remove-Item -LiteralPath $startupShortcut -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath $desktopShortcut -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath $startMenuDir -Recurse -Force -ErrorAction SilentlyContinue

$deleteCommand = 'timeout /t 2 /nobreak >nul & rmdir /s /q "{0}"' -f $installDir
Start-Process -FilePath 'cmd.exe' -ArgumentList '/c', $deleteCommand -WindowStyle Hidden

$message = 'WHAM Quick Replies удалён.'
if ($backupPath) { $message += "`r`n`r`nРезервная копия макросов:`r`n$backupPath" }
[System.Windows.Forms.MessageBox]::Show($message, 'WHAM Quick Replies', 'OK', 'Information') | Out-Null
'@

[IO.File]::WriteAllText(
    (Join-Path $installDir 'uninstall-wham.ps1'),
    $uninstallScript,
    [Text.UTF8Encoding]::new($true)
)

$uninstallCmd = "@echo off`r`npowershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File `"%~dp0uninstall-wham.ps1`"`r`n"
[IO.File]::WriteAllText(
    (Join-Path $installDir 'uninstall-wham.cmd'),
    $uninstallCmd,
    [Text.Encoding]::ASCII
)

function New-WhamShortcut {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Target,
        [string]$Arguments = '',
        [string]$Description = 'WHAM Quick Replies'
    )

    $shortcut = $shell.CreateShortcut($Path)
    $shortcut.TargetPath = $Target
    $shortcut.Arguments = $Arguments
    $shortcut.WorkingDirectory = $installDir
    $shortcut.Description = $Description
    $shortcut.IconLocation = 'shell32.dll,167'
    $shortcut.Save()
}

$appTarget = Join-Path $installDir 'start-wham.cmd'
$uninstallTarget = Join-Path $installDir 'uninstall-wham.cmd'
New-WhamShortcut -Path (Join-Path $startMenuDir 'WHAM Quick Replies.lnk') -Target $appTarget
New-WhamShortcut -Path (Join-Path $startMenuDir 'Удалить WHAM Quick Replies.lnk') -Target $uninstallTarget -Description 'Удалить WHAM Quick Replies'
New-WhamShortcut -Path (Join-Path $desktopDir 'WHAM Quick Replies.lnk') -Target $appTarget
New-WhamShortcut -Path $startupShortcut -Target $appTarget -Description 'Запускать WHAM Quick Replies вместе с Windows'

Start-Process -FilePath $appTarget -WorkingDirectory $installDir

[System.Windows.Forms.MessageBox]::Show(
    "WHAM Quick Replies установлен.`r`n`r`nПять макросов: Ctrl+Alt+1 — Ctrl+Alt+5.`r`nРедактор доступен через значок в системном трее.`r`nАвтозапуск Windows включён.`r`n`r`nПапка установки:`r`n$installDir",
    'WHAM Quick Replies',
    'OK',
    'Information'
) | Out-Null
