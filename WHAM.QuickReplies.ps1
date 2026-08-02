#requires -version 5.1

param(
    [string]$MacrosPath = (Join-Path $PSScriptRoot 'macros.json'),
    [switch]$SelfTest
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ([Threading.Thread]::CurrentThread.ApartmentState -ne 'STA') {
    throw 'WHAM must be started in STA mode. Use start-wham.cmd.'
}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

function Show-FatalStartupError {
    param([Parameter(Mandatory)][string]$Message)

    try {
        $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
        Add-Content -LiteralPath (Join-Path $PSScriptRoot 'WHAM-errors.log') -Encoding UTF8 -Value "[$timestamp] $Message"
    }
    catch {
        # A read-only folder must not hide the original startup error.
    }

    [System.Windows.Forms.MessageBox]::Show(
        "$Message`r`n`r`nПодробности сохранены в WHAM-errors.log.",
        'WHAM Quick Replies — ошибка запуска',
        'OK',
        'Error'
    ) | Out-Null
}

trap {
    if ($SelfTest) {
        [Console]::Error.WriteLine($_.Exception.ToString())
        exit 1
    }
    Show-FatalStartupError -Message $_.Exception.Message
    break
}

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

    public WhamHotkeyWindow() { CreateHandle(new CreateParams()); }

    public void Register(int id, uint modifiers, uint key)
    {
        if (!RegisterHotKey(Handle, id, modifiers, key))
            throw new InvalidOperationException("Hotkey registration failed for id " + id + ". Win32 error: " + Marshal.GetLastWin32Error());
    }

    public void Unregister(int id) { UnregisterHotKey(Handle, id); }

    protected override void WndProc(ref Message message)
    {
        if (message.Msg == WM_HOTKEY && HotkeyPressed != null)
            HotkeyPressed(message.WParam.ToInt32());
        base.WndProc(ref message);
    }

    public void Dispose() { DestroyHandle(); }
}
'@

function Read-Macros {
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "Macros file not found: $Path" }
    $parsed = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
    $items = @(foreach ($item in $parsed) { $item })
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
    try { $key = [System.Enum]::Parse([System.Windows.Forms.Keys], $keyName, $true) }
    catch { throw "Unsupported key '$keyName' in hotkey '$Hotkey'." }
    return [pscustomobject]@{ Modifiers = $modifiers; Key = [uint32]$key }
}

function Get-TemplateVariables {
    param([Parameter(Mandatory)][string]$Template)

    $seen = @{}
    $names = [Collections.Generic.List[string]]::new()
    foreach ($match in [regex]::Matches($Template, '\{(?<name>[\p{L}_][\p{L}\p{Nd}_]*)\}')) {
        $name = $match.Groups['name'].Value
        if (-not $seen.ContainsKey($name)) {
            $seen[$name] = $true
            $names.Add($name)
        }
    }
    return $names.ToArray()
}

function Expand-Template {
    param(
        [Parameter(Mandatory)][string]$Template,
        [Parameter(Mandatory)][Collections.IDictionary]$Values
    )

    $result = $Template
    foreach ($name in $Values.Keys) {
        $result = $result.Replace("{$name}", [string]$Values[$name])
    }
    return $result
}

function Show-TemplateDialog {
    param(
        [Parameter(Mandatory)][string]$Title,
        [Parameter(Mandatory)][string]$Template
    )

    $variables = @(Get-TemplateVariables -Template $Template)
    if ($variables.Count -eq 0) { return $Template }

    $form = [System.Windows.Forms.Form]::new()
    $form.Text = "WHAM — $Title"
    $form.StartPosition = 'CenterScreen'
    $form.FormBorderStyle = 'FixedDialog'
    $form.MinimizeBox = $false
    $form.MaximizeBox = $false
    $form.ShowInTaskbar = $true
    $form.ClientSize = [Drawing.Size]::new(560, (190 + [Math]::Min($variables.Count, 6) * 44))
    $form.Font = [Drawing.Font]::new('Segoe UI', 10)

    $inputs = @{}
    $top = 16
    foreach ($name in $variables) {
        $label = [System.Windows.Forms.Label]::new()
        $label.Text = $name.Replace('_', ' ')
        $label.Location = [Drawing.Point]::new(16, ($top + 5))
        $label.Size = [Drawing.Size]::new(155, 25)
        $form.Controls.Add($label)

        $input = [System.Windows.Forms.TextBox]::new()
        $input.Location = [Drawing.Point]::new(175, $top)
        $input.Size = [Drawing.Size]::new(365, 27)
        $form.Controls.Add($input)
        $inputs[$name] = $input
        $top += 44
    }

    $previewLabel = [System.Windows.Forms.Label]::new()
    $previewLabel.Text = 'Предпросмотр'
    $previewLabel.Location = [Drawing.Point]::new(16, $top)
    $previewLabel.Size = [Drawing.Size]::new(150, 24)
    $form.Controls.Add($previewLabel)
    $top += 25

    $preview = [System.Windows.Forms.TextBox]::new()
    $preview.Location = [Drawing.Point]::new(16, $top)
    $preview.Size = [Drawing.Size]::new(524, 90)
    $preview.Multiline = $true
    $preview.ScrollBars = 'Vertical'
    $preview.ReadOnly = $true
    $form.Controls.Add($preview)
    $top += 102

    $insertButton = [System.Windows.Forms.Button]::new()
    $insertButton.Text = 'Вставить'
    $insertButton.Location = [Drawing.Point]::new(340, $top)
    $insertButton.Size = [Drawing.Size]::new(95, 32)
    $form.Controls.Add($insertButton)

    $cancelButton = [System.Windows.Forms.Button]::new()
    $cancelButton.Text = 'Отмена'
    $cancelButton.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    $cancelButton.Location = [Drawing.Point]::new(445, $top)
    $cancelButton.Size = [Drawing.Size]::new(95, 32)
    $form.Controls.Add($cancelButton)

    $form.ClientSize = [Drawing.Size]::new(560, ($top + 48))
    $form.AcceptButton = $insertButton
    $form.CancelButton = $cancelButton

    $refreshPreview = {
        $values = @{}
        foreach ($name in $variables) { $values[$name] = $inputs[$name].Text }
        $preview.Text = Expand-Template -Template $Template -Values $values
    }
    foreach ($input in $inputs.Values) { $input.add_TextChanged($refreshPreview) }
    & $refreshPreview

    $insertButton.add_Click({
        $empty = @($variables | Where-Object { [string]::IsNullOrWhiteSpace($inputs[$_].Text) })
        if ($empty.Count -gt 0) {
            [System.Windows.Forms.MessageBox]::Show(
                "Заполните поля: $($empty -join ', ')",
                'WHAM Quick Replies',
                'OK',
                'Warning'
            ) | Out-Null
            return
        }
        $form.DialogResult = [System.Windows.Forms.DialogResult]::OK
        $form.Close()
    })

    try {
        if ($inputs.Count -gt 0) { $inputs[$variables[0]].Focus() | Out-Null }
        if ($form.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK) { return $null }
        return $preview.Text
    }
    finally { $form.Dispose() }
}

function Set-ClipboardTextWithRetry {
    param([Parameter(Mandatory)][string]$Text)
    $lastError = $null
    foreach ($attempt in 1..5) {
        try { [System.Windows.Forms.Clipboard]::SetText($Text); return }
        catch { $lastError = $_; Start-Sleep -Milliseconds 80 }
    }
    throw "Could not access the clipboard: $lastError"
}

function Restore-ClipboardSnapshot {
    param(
        [AllowNull()][object]$Snapshot,
        [Parameter(Mandatory)][string]$ExpectedText
    )

    try {
        if (-not [System.Windows.Forms.Clipboard]::ContainsText()) { return }
        if ([System.Windows.Forms.Clipboard]::GetText() -cne $ExpectedText) { return }

        if ($null -eq $Snapshot) {
            [System.Windows.Forms.Clipboard]::Clear()
        }
        else {
            [System.Windows.Forms.Clipboard]::SetDataObject($Snapshot, $true)
        }
    }
    catch {
        # Clipboard ownership can change at any time. Never overwrite newer
        # user data or interrupt the target application because restore failed.
    }
}

function Invoke-SafePaste {
    param([Parameter(Mandatory)][string]$Text)

    $snapshot = $null
    try { $snapshot = [System.Windows.Forms.Clipboard]::GetDataObject() }
    catch { $snapshot = $null }

    Set-ClipboardTextWithRetry -Text $Text
    try {
        [System.Windows.Forms.SendKeys]::SendWait('^v')
    }
    catch {
        Restore-ClipboardSnapshot -Snapshot $snapshot -ExpectedText $Text
        throw
    }

    $timer = [System.Windows.Forms.Timer]::new()
    $timer.Interval = 1000
    $restore = {
        param($sender, $eventArgs)
        $sender.Stop()
        try { Restore-ClipboardSnapshot -Snapshot $snapshot -ExpectedText $Text }
        finally {
            [void]$script:clipboardRestoreTimers.Remove($sender)
            $sender.Dispose()
        }
    }.GetNewClosure()
    $timer.add_Tick($restore)
    $script:clipboardRestoreTimers.Add($timer)
    $timer.Start()
}

if ($SelfTest) {
    $testMacros = @(Read-Macros -Path $MacrosPath)
    if ($testMacros.Count -ne 5) { throw "Self-test expected 5 macros, got $($testMacros.Count)." }

    $variables = @(Get-TemplateVariables -Template 'Добрый день, {имя}! Заказ №{номер}.')
    if (($variables -join ',') -ne 'имя,номер') { throw 'Variable extraction self-test failed.' }

    $rendered = Expand-Template -Template 'Добрый день, {имя}!' -Values @{ 'имя' = 'Тест' }
    if ($rendered -ne 'Добрый день, Тест!') { throw 'Template expansion self-test failed.' }

    $binding = ConvertTo-HotkeyBinding -Hotkey 'Ctrl+Alt+F24'
    $testWindow = [WhamHotkeyWindow]::new()
    try {
        $testWindow.Register(9001, $binding.Modifiers, $binding.Key)
        $testWindow.Unregister(9001)
    }
    finally { $testWindow.Dispose() }

    Write-Output 'WHAM Windows self-test passed.'
    exit 0
}

$macros = Read-Macros -Path $MacrosPath
$macrosById = @{}
$registeredIds = [Collections.Generic.List[int]]::new()
$script:clipboardRestoreTimers = [Collections.Generic.List[System.Windows.Forms.Timer]]::new()
$hotkeyWindow = [WhamHotkeyWindow]::new()
$notifyIcon = [System.Windows.Forms.NotifyIcon]::new()
$menu = [System.Windows.Forms.ContextMenuStrip]::new()

try {
    for ($index = 0; $index -lt $macros.Count; $index++) {
        $registrationId = $index + 1
        $binding = ConvertTo-HotkeyBinding -Hotkey ([string]$macros[$index].hotkey)
        try {
            $hotkeyWindow.Register($registrationId, $binding.Modifiers, $binding.Key)
        }
        catch {
            throw "Не удалось назначить '$($macros[$index].hotkey)' макросу '$($macros[$index].title)'. Сочетание занято другой программой или Windows. Измените поле hotkey в macros.json и перезапустите WHAM. $($_.Exception.Message)"
        }
        $registeredIds.Add($registrationId)
        $macrosById[$registrationId] = $macros[$index]
    }

    $hotkeyWindow.add_HotkeyPressed({
        param([int]$registrationId)
        try {
            $macro = $macrosById[$registrationId]
            $rendered = Show-TemplateDialog -Title ([string]$macro.title) -Template ([string]$macro.text)
            if ($null -eq $rendered) { return }
            Invoke-SafePaste -Text $rendered
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
    foreach ($timer in @($script:clipboardRestoreTimers)) {
        $timer.Stop()
        $timer.Dispose()
    }
    $notifyIcon.Visible = $false
    $notifyIcon.Dispose()
    $menu.Dispose()
    foreach ($id in $registeredIds) { $hotkeyWindow.Unregister($id) }
    $hotkeyWindow.Dispose()
}
