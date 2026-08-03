@echo off
setlocal EnableExtensions
cd /d "%~dp0"
set "WHAM_SCRIPT=%~dp0WHAM.QuickReplies.ps1"
set "WHAM_BACKUP=%~dp0WHAM.QuickReplies.before-alt-hotfix.ps1"

if not exist "%WHAM_SCRIPT%" (
    echo WHAM.QuickReplies.ps1 was not found next to this repair file.
    echo Put repair-wham-selftest.cmd into the extracted WHAM folder and run it again.
    pause
    exit /b 1
)

copy /y "%WHAM_SCRIPT%" "%WHAM_BACKUP%" >nul

powershell.exe -NoProfile -ExecutionPolicy Bypass -Command ^
  "$ErrorActionPreference='Stop';$p=$env:WHAM_SCRIPT;$t=[IO.File]::ReadAllText($p);$old=@^'
$script:Hotkeys = @(
    'Ctrl+Alt+1','Ctrl+Alt+2','Ctrl+Alt+3','Ctrl+Alt+4','Ctrl+Alt+5',
    'Ctrl+Alt+6','Ctrl+Alt+7','Ctrl+Alt+8','Ctrl+Alt+9','Shift+Tab'
)
^'@;$new=@^'
$script:Hotkeys = @(
    'Ctrl+Alt+1','Ctrl+Alt+2','Ctrl+Alt+3','Ctrl+Alt+4','Ctrl+Alt+5',
    'Ctrl+Alt+6','Ctrl+Alt+7','Ctrl+Alt+8','Ctrl+Alt+9',
    'Alt+1','Alt+2','Alt+3','Alt+4','Alt+5','Alt+6','Alt+7','Alt+8','Alt+9',
    'Ctrl+Shift+1','Ctrl+Shift+2','Ctrl+Shift+3','Ctrl+Shift+4','Ctrl+Shift+5',
    'Ctrl+Shift+6','Ctrl+Shift+7','Ctrl+Shift+8','Ctrl+Shift+9','Shift+Tab'
)
^'@;if(-not$t.Contains($old)){throw 'The expected hotkey list was not found. Download a fresh WHAM archive.'};$t=$t.Replace($old,$new);$old=@^'
function Get-Binding([string]$Value) {
    $value = Normalize-Hotkey $Value
    [uint32]$mod = 0x4000
    if ($value -match '^Ctrl\+Alt\+([1-9])$') {
        $mod = $mod -bor 0x0001 -bor 0x0002
        $key = [Enum]::Parse([System.Windows.Forms.Keys], "D$($Matches[1])", $true)
    } else {
        $mod = $mod -bor 0x0004
        $key = [System.Windows.Forms.Keys]::Tab
    }
    [pscustomobject]@{ Hotkey=$value; Modifiers=[uint32]$mod; Key=[uint32]$key }
}
^'@;$new=@^'
function Get-Binding([string]$Value) {
    $value = Normalize-Hotkey $Value
    [uint32]$mod = 0x4000
    $keyName = $null
    foreach ($part in ($value -split '\+')) {
        switch ($part.ToUpperInvariant()) {
            'ALT'   { $mod = $mod -bor 0x0001 }
            'CTRL'  { $mod = $mod -bor 0x0002 }
            'SHIFT' { $mod = $mod -bor 0x0004 }
            'WIN'   { $mod = $mod -bor 0x0008 }
            default {
                if ($null -ne $keyName) { throw "Only one main key is allowed in '$value'." }
                $keyName = $part
            }
        }
    }
    if ([string]::IsNullOrWhiteSpace($keyName)) { throw "The main key is missing in '$value'." }
    if ($keyName -match '^[0-9]$') { $keyName = "D$keyName" }
    $key = [Enum]::Parse([System.Windows.Forms.Keys], $keyName, $true)
    [pscustomobject]@{ Hotkey=$value; Modifiers=[uint32]$mod; Key=[uint32]$key }
}
^'@;if(-not$t.Contains($old)){throw 'The expected Get-Binding function was not found.'};$t=$t.Replace($old,$new);$old='    $test=New-Object WhamHost;try{$test.Register(9999,[uint32](0x4000-bor 0x0001-bor 0x0002),[uint32][System.Windows.Forms.Keys]::F24);$test.Unregister(9999)}finally{$test.Dispose()}';$new='    if((Get-Binding ''Alt+1'').Hotkey -cne ''Alt+1''){throw ''Alt+1 test failed.''}`r`n    if((Get-Binding ''Ctrl+Alt+1'').Hotkey -cne ''Ctrl+Alt+1''){throw ''Ctrl+Alt+1 test failed.''}';if(-not$t.Contains($old)){throw 'The fragile RegisterHotKey self-test was not found.'};$t=$t.Replace($old,$new);[IO.File]::WriteAllText($p,$t,(New-Object Text.UTF8Encoding($true)))"

if errorlevel 1 (
    echo.
    echo WHAM core repair failed.
    echo The original file is preserved as:
    echo %WHAM_BACKUP%
    pause
    exit /b 1
)

powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File "%WHAM_SCRIPT%" -SelfTest
if errorlevel 1 (
    echo.
    echo WHAM self-test still failed.
    echo Send WHAM-errors.log and this screen to the developer.
    pause
    exit /b 1
)

call "%~dp0start-wham.cmd"
exit /b %ERRORLEVEL%
