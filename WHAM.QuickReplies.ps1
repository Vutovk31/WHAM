#requires -version 5.1

param(
    [string]$MacrosPath = (Join-Path $PSScriptRoot 'macros.json')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ([Threading.Thread]::CurrentThread.ApartmentState -ne 'STA') {
    throw 'WHAM must be started in STA mode. Use start-wham.cmd.'
}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Windows.Forms;

public sealed class WhamHotkeyWindow : NativeWindow, IDisposable
{
    private const int WM_HOTKEY = 0x0312;

    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool RegisterHotKey(IntPtr hWnd, int id, uint modifiers, uint key);

    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool UnregisterHotKey(IntPtr hWnd, int id);

    public event Action<int> HotkeyPressed;

    public WhamHotkeyWindow()
    {
        CreateHandle(new CreateParams());
    }

    public void Register(int id, uint modifiers, uint key)
    {
        if (!RegisterHotKey(Handle, id, modifiers, key))
            throw new InvalidOperationException("Hotkey registration failed for id " + id + ". Win32 error: " + Marshal.GetLastWin32Error());
    }

    public void Unregister(int id)
    {
        UnregisterHotKey(Handle, id);
    }

    protected override void WndProc(ref Message message)
    {
        if (message.Msg == WM_HOTKEY && HotkeyPressed != null)
            HotkeyPressed(message.WParam.ToInt32());
        base.WndProc(ref message);
    }

    public void Dispose()
    {
        DestroyHandle();
    }
}
'@

function Read-Macros {
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Macros file not found: $Path"
    }

    $items = @(Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json)
    if ($items.Count -eq 0) { throw 'At least one macro is required.' }

    $seenHotkeys = @{}
    foreach ($item in $items) {
        foreach ($property in 'id', 'title', 'hotkey', 'text') {
            if (-not $item.PSObject.Properties[$property] -or [string]::IsNullOrWhiteSpace([string]$item.$property)) {
                throw "Macro is missing required property '$property'."
            }
        }

        $normalized = ([string]$item.hotkey).ToUpperInvariant()
        if ($seenHotkeys.ContainsKey($normalized)) { throw "Duplicate hotkey: $($item.hotkey)" }
        $seenHotkeys[$normalized] = $true
    }

    return $items
}

function ConvertTo-HotkeyBinding {
    param([Parameter(Mandatory)][string]$Hotkey)

    $modifiers = [uint32]0
    $keyName = $null
    foreach ($part in ($Hotkey -split '\+')) {
        switch ($part.Trim().ToUpperInvariant()) {
            'ALT'     { $modifiers = $modifiers -bor 0x0001 }
            'CTRL'    { $modifiers = $modifiers -bor 0x0002 }
            'CONTROL' { $modifiers = $modifiers -bor 0x0002 }
            'SHIFT'   { $modifiers = $modifiers -bor 0x0004 }
            'WIN'     { $modifiers = $modifiers -bor 0x0008 }
            default {
                if ($keyName) { throw "Hotkey must contain exactly one key: $Hotkey" }
                $keyName = $part.Trim()
            }
        }
    }

    if (-not $keyName) { throw "Hotkey has no key: $Hotkey" }
    if ($keyName -match '^[0-9]$') { $keyName = "D$keyName" }
    try {
        $key = [System.Enum]::Parse([System.Windows.Forms.Keys], $keyName, $true)
    }
    catch {
        throw "Unsupported key '$keyName' in hotkey '$Hotkey'."
    }

    return [pscustomobject]@{ Modifiers = $modifiers; Key = [uint32]$key }
}

function Set-ClipboardTextWithRetry {
    param([Parameter(Mandatory)][string]$Text)

    $lastError = $null
    foreach ($attempt in 1..5) {
        try {
            [System.Windows.Forms.Clipboard]::SetText($Text)
            return
        }
        catch {
            $lastError = $_
            Start-Sleep -Milliseconds 80
        }
    }
    throw "Could not access the clipboard: $lastError"
}

$macros = Read-Macros -Path $MacrosPath
$macrosById = @{}
$registeredIds = [Collections.Generic.List[int]]::new()
$hotkeyWindow = [WhamHotkeyWindow]::new()
$notifyIcon = [System.Windows.Forms.NotifyIcon]::new()
$menu = [System.Windows.Forms.ContextMenuStrip]::new()

try {
    for ($index = 0; $index -lt $macros.Count; $index++) {
        $registrationId = $index + 1
        $binding = ConvertTo-HotkeyBinding -Hotkey ([string]$macros[$index].hotkey)
        $hotkeyWindow.Register($registrationId, $binding.Modifiers, $binding.Key)
        $registeredIds.Add($registrationId)
        $macrosById[$registrationId] = $macros[$index]
    }

    $hotkeyWindow.add_HotkeyPressed({
        param([int]$registrationId)
        try {
            $macro = $macrosById[$registrationId]
            Set-ClipboardTextWithRetry -Text ([string]$macro.text)
            [System.Windows.Forms.SendKeys]::SendWait('^v')
        }
        catch {
            [System.Windows.Forms.MessageBox]::Show(
                "WHAM could not insert the macro.`r`n`r`n$($_.Exception.Message)",
                'WHAM Quick Replies',
                'OK',
                'Error'
            ) | Out-Null
        }
    })

    $openMacros = $menu.Items.Add('Open macros.json')
    $openMacros.add_Click({ Start-Process -FilePath 'notepad.exe' -ArgumentList ('"{0}"' -f $MacrosPath) })
    $menu.Items.Add('-') | Out-Null
    $exitItem = $menu.Items.Add('Exit')
    $exitItem.add_Click({ [System.Windows.Forms.Application]::Exit() })

    $notifyIcon.Icon = [System.Drawing.SystemIcons]::Information
    $notifyIcon.Text = 'WHAM Quick Replies'
    $notifyIcon.ContextMenuStrip = $menu
    $notifyIcon.Visible = $true
    $notifyIcon.ShowBalloonTip(2500, 'WHAM Quick Replies', "$($macros.Count) macros are active.", 'Info')

    [System.Windows.Forms.Application]::Run()
}
finally {
    $notifyIcon.Visible = $false
    $notifyIcon.Dispose()
    $menu.Dispose()
    foreach ($id in $registeredIds) { $hotkeyWindow.Unregister($id) }
    $hotkeyWindow.Dispose()
}
