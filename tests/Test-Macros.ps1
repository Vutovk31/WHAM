#requires -version 5.1

$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$macrosPath = Join-Path $root 'macros.json'
$scriptPath = Join-Path $root 'WHAM.QuickReplies.ps1'

$parsed = Get-Content -LiteralPath $macrosPath -Raw -Encoding UTF8 | ConvertFrom-Json
$macros = @(foreach ($macro in $parsed) { $macro })

if ($macros.Count -eq 0) {
    throw 'At least one starter macro is required.'
}

$ids = @{}
$hotkeys = @{}
foreach ($macro in $macros) {
    foreach ($property in @('id','title','hotkey','text')) {
        if (-not $macro.PSObject.Properties[$property]) {
            throw "Macro is missing '$property'."
        }
        if ([string]::IsNullOrWhiteSpace([string]$macro.$property)) {
            throw "Macro property '$property' is empty."
        }
    }

    $id = ([string]$macro.id).Trim()
    $hotkey = (([string]$macro.hotkey) -replace '\s','').ToUpperInvariant()
    if ($ids.ContainsKey($id)) { throw "Duplicate macro id: $id" }
    if ($hotkeys.ContainsKey($hotkey)) { throw "Duplicate hotkey: $hotkey" }
    $ids[$id] = $true
    $hotkeys[$hotkey] = $true
}

$expected = @(1..5 | ForEach-Object { "CTRL+ALT+$_" })
$actual = @($hotkeys.Keys | Sort-Object)
if (@(Compare-Object $expected $actual).Count -ne 0) {
    throw 'Starter hotkeys must be Ctrl+Alt+1 through Ctrl+Alt+5.'
}

$tokens = $null
$parseErrors = $null
[void][System.Management.Automation.Language.Parser]::ParseFile(
    $scriptPath,
    [ref]$tokens,
    [ref]$parseErrors
)
if ($parseErrors.Count -gt 0) {
    throw (($parseErrors | ForEach-Object { $_.Message }) -join "`r`n")
}

$script = [IO.File]::ReadAllText($scriptPath)
foreach ($contract in @(
    '[switch]$SelfTest',
    'function Read-Macros',
    'function Save-Macros',
    'function Backup-File',
    'function Register-All',
    'function Paste-Text',
    'System.Threading.Mutex',
    'RegisterHotKey',
    'WHAM self-test passed.'
)) {
    if (-not $script.Contains($contract)) {
        throw "Missing minimal beta contract: $contract"
    }
}

if ($script.Contains('function Register-All([WhamWindow]$Host')) {
    throw 'Protected PowerShell variable $Host must not be used as a parameter.'
}

$selfTestStart = $script.IndexOf('function Run-SelfTest')
$appStart = $script.IndexOf('function Run-App')
if ($selfTestStart -lt 0 -or $appStart -le $selfTestStart) {
    throw 'Self-test block is missing.'
}
$selfTestBlock = $script.Substring($selfTestStart, $appStart - $selfTestStart)
if ($selfTestBlock.Contains('.RegisterBinding(')) {
    throw 'Self-test must not register a real global hotkey.'
}

Write-Host 'Minimal WHAM beta validation passed.'
