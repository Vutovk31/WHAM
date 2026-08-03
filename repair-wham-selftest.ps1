#requires -version 5.1

$ErrorActionPreference = 'Stop'

$scriptPath = Join-Path $PSScriptRoot 'WHAM.QuickReplies.ps1'
$backupPath = Join-Path $PSScriptRoot 'WHAM.QuickReplies.before-alt-hotfix.ps1'
$startPath = Join-Path $PSScriptRoot 'start-wham.cmd'

if (-not (Test-Path -LiteralPath $scriptPath -PathType Leaf)) {
    throw "WHAM.QuickReplies.ps1 was not found next to this repair file: $scriptPath"
}
if (-not (Test-Path -LiteralPath $startPath -PathType Leaf)) {
    throw "start-wham.cmd was not found next to this repair file: $startPath"
}

Copy-Item -LiteralPath $scriptPath -Destination $backupPath -Force
$text = [IO.File]::ReadAllText($scriptPath)

$oldHotkeys = @'
$script:Hotkeys = @(
    'Ctrl+Alt+1','Ctrl+Alt+2','Ctrl+Alt+3','Ctrl+Alt+4','Ctrl+Alt+5',
    'Ctrl+Alt+6','Ctrl+Alt+7','Ctrl+Alt+8','Ctrl+Alt+9','Shift+Tab'
)
'@
$newHotkeys = @'
$script:Hotkeys = @(
    'Ctrl+Alt+1','Ctrl+Alt+2','Ctrl+Alt+3','Ctrl+Alt+4','Ctrl+Alt+5',
    'Ctrl+Alt+6','Ctrl+Alt+7','Ctrl+Alt+8','Ctrl+Alt+9',
    'Alt+1','Alt+2','Alt+3','Alt+4','Alt+5','Alt+6','Alt+7','Alt+8','Alt+9',
    'Ctrl+Shift+1','Ctrl+Shift+2','Ctrl+Shift+3','Ctrl+Shift+4','Ctrl+Shift+5',
    'Ctrl+Shift+6','Ctrl+Shift+7','Ctrl+Shift+8','Ctrl+Shift+9','Shift+Tab'
)
'@

if ($text.Contains($oldHotkeys)) {
    $text = $text.Replace($oldHotkeys, $newHotkeys)
}
elseif (-not $text.Contains("'Alt+1','Alt+2','Alt+3'")) {
    throw 'The expected hotkey list was not found. Download a fresh WHAM archive.'
}

$oldBinding = @'
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
'@
$newBinding = @'
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
    try { $key = [Enum]::Parse([System.Windows.Forms.Keys], $keyName, $true) }
    catch { throw "Key '$keyName' is not supported by Windows." }
    [pscustomobject]@{ Hotkey=$value; Modifiers=[uint32]$mod; Key=[uint32]$key }
}
'@

if ($text.Contains($oldBinding)) {
    $text = $text.Replace($oldBinding, $newBinding)
}
elseif (-not $text.Contains('$keyName = $null')) {
    throw 'The expected Get-Binding function was not found.'
}

$oldSelfTest = '    $test=New-Object WhamHost;try{$test.Register(9999,[uint32](0x4000-bor 0x0001-bor 0x0002),[uint32][System.Windows.Forms.Keys]::F24);$test.Unregister(9999)}finally{$test.Dispose()}'
$newSelfTest = @'
    if((Get-Binding 'Alt+1').Hotkey -cne 'Alt+1'){throw 'Alt+1 test failed.'}
    if((Get-Binding 'Ctrl+Alt+1').Hotkey -cne 'Ctrl+Alt+1'){throw 'Ctrl+Alt+1 test failed.'}
'@

if ($text.Contains($oldSelfTest)) {
    $text = $text.Replace($oldSelfTest, $newSelfTest.TrimEnd())
}
elseif ($text.Contains('$test.Register(9999')) {
    throw 'The fragile RegisterHotKey self-test could not be replaced.'
}

[IO.File]::WriteAllText($scriptPath, $text, (New-Object Text.UTF8Encoding($true)))

$tokens = $null
$parseErrors = $null
[void][System.Management.Automation.Language.Parser]::ParseFile(
    $scriptPath,
    [ref]$tokens,
    [ref]$parseErrors
)
if ($parseErrors.Count -gt 0) {
    Copy-Item -LiteralPath $backupPath -Destination $scriptPath -Force
    throw (($parseErrors | ForEach-Object { $_.Message }) -join "`r`n")
}

& powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File $scriptPath -SelfTest
if ($LASTEXITCODE -ne 0) {
    Copy-Item -LiteralPath $backupPath -Destination $scriptPath -Force
    throw "WHAM self-test still failed. Original file restored from $backupPath"
}

& $startPath
exit $LASTEXITCODE
