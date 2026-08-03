#requires -version 5.1

param(
    [ValidateRange(3, 30)]
    [int]$StartupTimeoutSeconds = 10
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ([Threading.Thread]::CurrentThread.ApartmentState -ne 'STA') {
    throw 'Run this acceptance test in STA mode: powershell.exe -NoProfile -STA -File .\tests\Test-NotepadPaste.ps1'
}

Add-Type -AssemblyName System.Windows.Forms

function Set-ClipboardTextWithRetry {
    param([Parameter(Mandatory)][string]$Text)

    $lastError = $null
    foreach ($attempt in 1..10) {
        try {
            [System.Windows.Forms.Clipboard]::SetText($Text)
            return
        }
        catch {
            $lastError = $_
            Start-Sleep -Milliseconds 100
        }
    }
    throw "Could not write to the clipboard: $lastError"
}

function Get-ClipboardTextWithRetry {
    $lastError = $null
    foreach ($attempt in 1..10) {
        try {
            if ([System.Windows.Forms.Clipboard]::ContainsText()) {
                return [System.Windows.Forms.Clipboard]::GetText()
            }
        }
        catch {
            $lastError = $_
        }
        Start-Sleep -Milliseconds 100
    }
    throw "Could not read pasted text back from the clipboard: $lastError"
}

function Normalize-Newlines {
    param([AllowEmptyString()][string]$Text)
    return $Text.Replace("`r`n", "`n").Replace("`r", "`n")
}

$expected = "WHAM проверка Unicode`r`nСтрока 2: заказ №123 — готово."
$tempFile = Join-Path ([IO.Path]::GetTempPath()) "WHAM-acceptance-$([Guid]::NewGuid().ToString('N')).txt"
$notepad = $null
$clipboardSnapshot = $null

try {
    try { $clipboardSnapshot = [System.Windows.Forms.Clipboard]::GetDataObject() }
    catch { $clipboardSnapshot = $null }

    [IO.File]::WriteAllText($tempFile, '', [Text.UTF8Encoding]::new($true))
    $notepad = Start-Process -FilePath 'notepad.exe' -ArgumentList ('"{0}"' -f $tempFile) -PassThru
    $shell = New-Object -ComObject WScript.Shell
    $deadline = [DateTime]::UtcNow.AddSeconds($StartupTimeoutSeconds)
    $activated = $false

    while ([DateTime]::UtcNow -lt $deadline) {
        $notepad.Refresh()
        if ($notepad.HasExited) {
            throw 'Notepad exited before the acceptance test could activate its window.'
        }

        if ($shell.AppActivate($notepad.Id) -or $shell.AppActivate([IO.Path]::GetFileName($tempFile))) {
            $activated = $true
            break
        }
        Start-Sleep -Milliseconds 200
    }

    if (-not $activated) {
        throw "Could not activate Notepad within $StartupTimeoutSeconds seconds. Close modal windows and retry."
    }

    Start-Sleep -Milliseconds 300
    Set-ClipboardTextWithRetry -Text $expected
    [System.Windows.Forms.SendKeys]::SendWait('^v')
    Start-Sleep -Milliseconds 250

    [System.Windows.Forms.SendKeys]::SendWait('^a')
    [System.Windows.Forms.SendKeys]::SendWait('^c')
    Start-Sleep -Milliseconds 300
    $actual = Get-ClipboardTextWithRetry

    if ((Normalize-Newlines -Text $actual) -cne (Normalize-Newlines -Text $expected)) {
        throw "Notepad paste verification failed. Expected '$expected', received '$actual'."
    }

    Write-Output 'WHAM Notepad Unicode multiline paste acceptance passed.'
}
finally {
    if ($null -ne $notepad) {
        try {
            $notepad.Refresh()
            if (-not $notepad.HasExited) { Stop-Process -Id $notepad.Id -Force }
        }
        catch {
            # The isolated test process may already have closed.
        }
    }

    Remove-Item -LiteralPath $tempFile -Force -ErrorAction SilentlyContinue

    try {
        if ($null -eq $clipboardSnapshot) {
            [System.Windows.Forms.Clipboard]::Clear()
        }
        else {
            [System.Windows.Forms.Clipboard]::SetDataObject($clipboardSnapshot, $true)
        }
    }
    catch {
        Write-Warning 'The acceptance test passed or failed, but the previous clipboard contents could not be restored.'
    }
}
