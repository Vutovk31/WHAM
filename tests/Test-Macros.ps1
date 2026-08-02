#requires -version 5.1

$ErrorActionPreference = 'Stop'
$path = Join-Path (Split-Path $PSScriptRoot -Parent) 'macros.json'
$parsed = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
$macros = @(foreach ($macro in $parsed) { $macro })

if ($macros.Count -ne 5) { throw "Expected 5 starter macros, got $($macros.Count)." }
$required = 'id', 'title', 'hotkey', 'text'
foreach ($macro in $macros) {
    foreach ($property in $required) {
        if (-not $macro.PSObject.Properties[$property] -or [string]::IsNullOrWhiteSpace([string]$macro.$property)) {
            throw "Macro is missing '$property'."
        }
    }
}

$hotkeys = @($macros | ForEach-Object { ([string]$_.hotkey).ToUpperInvariant() })
if (@($hotkeys | Select-Object -Unique).Count -ne $hotkeys.Count) { throw 'Starter hotkeys are not unique.' }
$expected = 1..5 | ForEach-Object { "CTRL+ALT+$_" }
if (@(Compare-Object $expected $hotkeys).Count -ne 0) { throw 'Starter hotkeys must be Ctrl+Alt+1 through Ctrl+Alt+5.' }

$variablePattern = '\{(?<name>[\p{L}_][\p{L}\p{Nd}_]*)\}'
foreach ($macro in $macros) {
    $names = @([regex]::Matches([string]$macro.text, $variablePattern) | ForEach-Object { $_.Groups['name'].Value })
    if ($names.Count -eq 0) { throw "Starter macro '$($macro.id)' must exercise variable rendering." }
}

Write-Host 'macros.json validation passed.'
