#requires -version 5.1

param(
    [string]$MacrosPath = (Join-Path $PSScriptRoot 'macros.json'),
    [switch]$SelfTest
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ([Threading.Thread]::CurrentThread.ApartmentState -ne 'STA') {
    throw 'WHAM должен запускаться в STA-режиме через start-wham.cmd.'
}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$script:ErrorLogPath = Join-Path $PSScriptRoot 'WHAM-errors.log'
$script:StatusPath = Join-Path $PSScriptRoot 'WHAM-status.txt'

function Write-WhamError {
    param([Parameter(Mandatory)][string]$Message)

    try {
        $line = '[{0}] {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message
        Add-Content -LiteralPath $script:ErrorLogPath -Value $line -Encoding UTF8
    }
    catch {
        # Ошибка журнала не должна скрывать исходную ошибку.
    }
}

function Show-WhamError {
    param([Parameter(Mandatory)][string]$Message)

    Write-WhamError -Message $Message
    [System.Windows.Forms.MessageBox]::Show(
        "$Message`r`n`r`nПодробности записаны в WHAM-errors.log.",
        'WHAM Quick Replies — ошибка',
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Error
    ) | Out-Null
}

function Write-WhamStatus {
    param(
        [Parameter(Mandatory)][string]$Status,
        [string[]]$Details = @()
    )

    try {
        $lines = @(
            "STATUS: $Status"
            "TIME: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
            "PID: $PID"
        ) + $Details
        [IO.File]::WriteAllLines($script:StatusPath, $lines, (New-Object Text.UTF8Encoding($true)))
    }
    catch {
        Write-WhamError -Message "Не удалось обновить WHAM-status.txt: $($_.Exception.Message)"
    }
}

Add-Type -ReferencedAssemblies 'System.Windows.Forms.dll','System.Drawing.dll' -TypeDefinition @'
using System;
using System.Drawing;
using System.Runtime.InteropServices;
using System.Windows.Forms;

public sealed class WhamHotkeyForm : Form
{
    private const int WM_HOTKEY = 0x0312;
    private const uint KEYEVENTF_KEYUP = 0x0002;
    private const byte VK_CONTROL = 0x11;
    private const byte VK_V = 0x56;

    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool RegisterHotKey(IntPtr hWnd, int id, uint modifiers, uint key);

    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool UnregisterHotKey(IntPtr hWnd, int id);

    [DllImport("user32.dll")]
    public static extern IntPtr GetForegroundWindow();

    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool SetForegroundWindow(IntPtr hWnd);

    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool IsWindow(IntPtr hWnd);

    [DllImport("user32.dll")]
    public static extern short GetAsyncKeyState(int virtualKey);

    [DllImport("user32.dll")]
    private static extern void keybd_event(byte virtualKey, byte scanCode, uint flags, UIntPtr extraInfo);

    public event Action<int> HotkeyPressed;

    public WhamHotkeyForm()
    {
        ShowInTaskbar = false;
        FormBorderStyle = FormBorderStyle.FixedToolWindow;
        StartPosition = FormStartPosition.Manual;
        Location = new Point(-32000, -32000);
        Size = new Size(1, 1);
        Opacity = 0;
    }

    protected override void SetVisibleCore(bool value)
    {
        base.SetVisibleCore(false);
    }

    public void Register(int id, uint modifiers, uint key)
    {
        IntPtr handle = Handle;
        if (!RegisterHotKey(handle, id, modifiers, key))
        {
            throw new InvalidOperationException(
                "RegisterHotKey failed. Win32 error: " + Marshal.GetLastWin32Error()
            );
        }
    }

    public void Unregister(int id)
    {
        if (IsHandleCreated)
        {
            UnregisterHotKey(Handle, id);
        }
    }

    public static void SendCtrlV()
    {
        keybd_event(VK_CONTROL, 0, 0, UIntPtr.Zero);
        keybd_event(VK_V, 0, 0, UIntPtr.Zero);
        keybd_event(VK_V, 0, KEYEVENTF_KEYUP, UIntPtr.Zero);
        keybd_event(VK_CONTROL, 0, KEYEVENTF_KEYUP, UIntPtr.Zero);
    }

    protected override void WndProc(ref Message message)
    {
        if (message.Msg == WM_HOTKEY && HotkeyPressed != null)
        {
            HotkeyPressed(message.WParam.ToInt32());
        }
        base.WndProc(ref message);
    }
}
'@

function Read-Macros {
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Файл макросов не найден: $Path"
    }

    try {
        $raw = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
        $parsed = $raw | ConvertFrom-Json
    }
    catch {
        throw "Не удалось прочитать macros.json. Проверьте кавычки и запятые.`r`n$($_.Exception.Message)"
    }

    $items = @($parsed)
    if ($items.Count -eq 0) {
        throw 'В macros.json должен быть хотя бы один макрос.'
    }

    $ids = @{}
    $hotkeys = @{}
    foreach ($item in $items) {
        foreach ($property in @('id', 'title', 'hotkey', 'text')) {
            if (-not $item.PSObject.Properties[$property]) {
                throw "У макроса отсутствует поле '$property'."
            }
            if ([string]::IsNullOrWhiteSpace([string]$item.$property)) {
                throw "Поле '$property' не может быть пустым."
            }
        }

        $id = ([string]$item.id).Trim()
        $hotkey = ([string]$item.hotkey).Trim().ToUpperInvariant()
        if ($ids.ContainsKey($id)) {
            throw "Повторяется id макроса: $id"
        }
        if ($hotkeys.ContainsKey($hotkey)) {
            throw "Сочетание '$($item.hotkey)' назначено нескольким макросам."
        }
        $ids[$id] = $true
        $hotkeys[$hotkey] = $true
    }

    return $items
}

function ConvertTo-SerializableMacros {
    param([Parameter(Mandatory)][System.Collections.IEnumerable]$Macros)

    return @(
        foreach ($macro in $Macros) {
            [pscustomobject]@{
                id = [string]$macro.id
                title = [string]$macro.title
                hotkey = [string]$macro.hotkey
                text = [string]$macro.text
            }
        }
    )
}

function Write-MacrosVerified {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][System.Collections.IEnumerable]$Macros
    )

    $items = @(ConvertTo-SerializableMacros -Macros $Macros)
    if ($items.Count -eq 0) {
        throw 'Нельзя сохранить пустой список макросов.'
    }

    $json = ConvertTo-Json -InputObject $items -Depth 4
    $tempPath = "$Path.tmp"
    $backupPath = "$Path.bak"

    try {
        [IO.File]::WriteAllText($tempPath, $json, (New-Object Text.UTF8Encoding($true)))
        if (Test-Path -LiteralPath $Path -PathType Leaf) {
            Copy-Item -LiteralPath $Path -Destination $backupPath -Force
        }
        Move-Item -LiteralPath $tempPath -Destination $Path -Force

        $saved = @(Read-Macros -Path $Path)
        $expected = ConvertTo-Json -InputObject $items -Depth 4 -Compress
        $actual = ConvertTo-Json -InputObject (ConvertTo-SerializableMacros -Macros $saved) -Depth 4 -Compress
        if ($expected -cne $actual) {
            throw 'Проверка сохранённого файла не прошла.'
        }
    }
    catch {
        if (Test-Path -LiteralPath $backupPath -PathType Leaf) {
            Copy-Item -LiteralPath $backupPath -Destination $Path -Force -ErrorAction SilentlyContinue
        }
        throw
    }
    finally {
        Remove-Item -LiteralPath $tempPath -Force -ErrorAction SilentlyContinue
    }
}

function ConvertTo-HotkeyBinding {
    param([Parameter(Mandatory)][string]$Hotkey)

    [uint32]$modifiers = 0x4000 # MOD_NOREPEAT
    $keyName = $null

    foreach ($part in ($Hotkey -split '\+')) {
        $token = $part.Trim().ToUpperInvariant()
        switch ($token) {
            'ALT'     { $modifiers = $modifiers -bor 0x0001 }
            'CTRL'    { $modifiers = $modifiers -bor 0x0002 }
            'CONTROL' { $modifiers = $modifiers -bor 0x0002 }
            'SHIFT'   { $modifiers = $modifiers -bor 0x0004 }
            'WIN'     { $modifiers = $modifiers -bor 0x0008 }
            default {
                if ([string]::IsNullOrWhiteSpace($token)) { continue }
                if ($null -ne $keyName) {
                    throw "В сочетании должна быть одна обычная клавиша: $Hotkey"
                }
                $keyName = $token
            }
        }
    }

    if ([string]::IsNullOrWhiteSpace($keyName)) {
        throw "В сочетании отсутствует обычная клавиша: $Hotkey"
    }
    if ($keyName -match '^[0-9]$') {
        $keyName = "D$keyName"
    }

    try {
        $key = [System.Enum]::Parse([System.Windows.Forms.Keys], $keyName, $true)
    }
    catch {
        throw "Клавиша '$keyName' не поддерживается в сочетании '$Hotkey'."
    }

    return [pscustomobject]@{
        Modifiers = $modifiers
        Key = [uint32]$key
    }
}

function New-HotkeyPlan {
    param([Parameter(Mandatory)][object[]]$Macros)

    $plan = @()
    for ($index = 0; $index -lt $Macros.Count; $index++) {
        $binding = ConvertTo-HotkeyBinding -Hotkey ([string]$Macros[$index].hotkey)
        $plan += [pscustomobject]@{
            RegistrationId = 1001 + $index
            Binding = $binding
            MacroId = [string]$Macros[$index].id
            Title = [string]$Macros[$index].title
            Hotkey = [string]$Macros[$index].hotkey
        }
    }
    return $plan
}

function Get-TemplateVariables {
    param([Parameter(Mandatory)][string]$Template)

    $seen = @{}
    $result = New-Object 'System.Collections.Generic.List[string]'
    foreach ($match in [regex]::Matches($Template, '\{(?<name>[\p{L}_][\p{L}\p{Nd}_]*)\}')) {
        $name = $match.Groups['name'].Value
        if (-not $seen.ContainsKey($name)) {
            $seen[$name] = $true
            $result.Add($name)
        }
    }
    return $result.ToArray()
}

function Expand-Template {
    param(
        [Parameter(Mandatory)][string]$Template,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Values
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
    if ($variables.Count -eq 0) {
        return $Template
    }

    $form = New-Object System.Windows.Forms.Form
    $form.Text = "WHAM — $Title"
    $form.StartPosition = 'CenterScreen'
    $form.FormBorderStyle = 'FixedDialog'
    $form.MinimizeBox = $false
    $form.MaximizeBox = $false
    $form.ShowInTaskbar = $true
    $form.Font = New-Object Drawing.Font('Segoe UI', 10)

    $inputs = @{}
    $top = 16
    foreach ($name in $variables) {
        $label = New-Object System.Windows.Forms.Label
        $label.Text = $name.Replace('_', ' ')
        $label.Location = New-Object Drawing.Point(16, ($top + 4))
        $label.Size = New-Object Drawing.Size(145, 25)
        $form.Controls.Add($label)

        $input = New-Object System.Windows.Forms.TextBox
        $input.Location = New-Object Drawing.Point(165, $top)
        $input.Size = New-Object Drawing.Size(375, 27)
        $form.Controls.Add($input)
        $inputs[$name] = $input
        $top += 42
    }

    $previewLabel = New-Object System.Windows.Forms.Label
    $previewLabel.Text = 'Предпросмотр'
    $previewLabel.Location = New-Object Drawing.Point(16, $top)
    $previewLabel.Size = New-Object Drawing.Size(140, 24)
    $form.Controls.Add($previewLabel)
    $top += 25

    $preview = New-Object System.Windows.Forms.TextBox
    $preview.Location = New-Object Drawing.Point(16, $top)
    $preview.Size = New-Object Drawing.Size(524, 110)
    $preview.Multiline = $true
    $preview.ScrollBars = 'Vertical'
    $preview.ReadOnly = $true
    $form.Controls.Add($preview)
    $top += 122

    $insertButton = New-Object System.Windows.Forms.Button
    $insertButton.Text = 'Вставить'
    $insertButton.Location = New-Object Drawing.Point(340, $top)
    $insertButton.Size = New-Object Drawing.Size(95, 32)
    $form.Controls.Add($insertButton)

    $cancelButton = New-Object System.Windows.Forms.Button
    $cancelButton.Text = 'Отмена'
    $cancelButton.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    $cancelButton.Location = New-Object Drawing.Point(445, $top)
    $cancelButton.Size = New-Object Drawing.Size(95, 32)
    $form.Controls.Add($cancelButton)

    $form.ClientSize = New-Object Drawing.Size(560, ($top + 48))
    $form.AcceptButton = $insertButton
    $form.CancelButton = $cancelButton

    $refreshPreview = {
        $values = @{}
        foreach ($name in $variables) {
            $values[$name] = $inputs[$name].Text
        }
        $preview.Text = Expand-Template -Template $Template -Values $values
    }

    foreach ($input in $inputs.Values) {
        $input.add_TextChanged($refreshPreview)
    }
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
        $inputs[$variables[0]].Focus() | Out-Null
        if ($form.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK) {
            return $null
        }
        return $preview.Text
    }
    finally {
        $form.Dispose()
    }
}

function Show-MacroEditor {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][object[]]$Macros
    )

    $items = New-Object System.Collections.ArrayList
    foreach ($macro in $Macros) {
        [void]$items.Add([pscustomobject]@{
            id = [string]$macro.id
            title = [string]$macro.title
            hotkey = [string]$macro.hotkey
            text = [string]$macro.text
        })
    }

    $state = [pscustomobject]@{ Loading = $false; CurrentIndex = -1 }

    $form = New-Object System.Windows.Forms.Form
    $form.Text = 'WHAM — редактор макросов'
    $form.StartPosition = 'CenterScreen'
    $form.MinimumSize = New-Object Drawing.Size(780, 520)
    $form.ClientSize = New-Object Drawing.Size(820, 540)
    $form.Font = New-Object Drawing.Font('Segoe UI', 10)

    $list = New-Object System.Windows.Forms.ListBox
    $list.Location = New-Object Drawing.Point(16, 16)
    $list.Size = New-Object Drawing.Size(220, 450)
    $list.Anchor = 'Top, Bottom, Left'
    foreach ($item in $items) { [void]$list.Items.Add($item.title) }
    $form.Controls.Add($list)

    $titleLabel = New-Object System.Windows.Forms.Label
    $titleLabel.Text = 'Название'
    $titleLabel.Location = New-Object Drawing.Point(252, 18)
    $titleLabel.Size = New-Object Drawing.Size(100, 24)
    $form.Controls.Add($titleLabel)

    $titleInput = New-Object System.Windows.Forms.TextBox
    $titleInput.Location = New-Object Drawing.Point(252, 43)
    $titleInput.Size = New-Object Drawing.Size(545, 27)
    $titleInput.Anchor = 'Top, Left, Right'
    $form.Controls.Add($titleInput)

    $hotkeyLabel = New-Object System.Windows.Forms.Label
    $hotkeyLabel.Text = 'Горячая клавиша: Ctrl+Alt+1, Ctrl+Alt+2 и т. д.'
    $hotkeyLabel.Location = New-Object Drawing.Point(252, 82)
    $hotkeyLabel.Size = New-Object Drawing.Size(500, 24)
    $form.Controls.Add($hotkeyLabel)

    $hotkeyInput = New-Object System.Windows.Forms.TextBox
    $hotkeyInput.Location = New-Object Drawing.Point(252, 107)
    $hotkeyInput.Size = New-Object Drawing.Size(545, 27)
    $hotkeyInput.Anchor = 'Top, Left, Right'
    $form.Controls.Add($hotkeyInput)

    $textLabel = New-Object System.Windows.Forms.Label
    $textLabel.Text = 'Текст макроса. Выражения в {скобках} запрашиваются перед вставкой.'
    $textLabel.Location = New-Object Drawing.Point(252, 146)
    $textLabel.Size = New-Object Drawing.Size(545, 24)
    $form.Controls.Add($textLabel)

    $textInput = New-Object System.Windows.Forms.TextBox
    $textInput.Location = New-Object Drawing.Point(252, 171)
    $textInput.Size = New-Object Drawing.Size(545, 295)
    $textInput.Multiline = $true
    $textInput.AcceptsReturn = $true
    $textInput.ScrollBars = 'Vertical'
    $textInput.Anchor = 'Top, Bottom, Left, Right'
    $form.Controls.Add($textInput)

    $addButton = New-Object System.Windows.Forms.Button
    $addButton.Text = 'Добавить'
    $addButton.Location = New-Object Drawing.Point(16, 482)
    $addButton.Size = New-Object Drawing.Size(105, 34)
    $addButton.Anchor = 'Bottom, Left'
    $form.Controls.Add($addButton)

    $deleteButton = New-Object System.Windows.Forms.Button
    $deleteButton.Text = 'Удалить'
    $deleteButton.Location = New-Object Drawing.Point(131, 482)
    $deleteButton.Size = New-Object Drawing.Size(105, 34)
    $deleteButton.Anchor = 'Bottom, Left'
    $form.Controls.Add($deleteButton)

    $saveButton = New-Object System.Windows.Forms.Button
    $saveButton.Text = 'Сохранить'
    $saveButton.Location = New-Object Drawing.Point(577, 482)
    $saveButton.Size = New-Object Drawing.Size(105, 34)
    $saveButton.Anchor = 'Bottom, Right'
    $form.Controls.Add($saveButton)

    $cancelButton = New-Object System.Windows.Forms.Button
    $cancelButton.Text = 'Отмена'
    $cancelButton.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    $cancelButton.Location = New-Object Drawing.Point(692, 482)
    $cancelButton.Size = New-Object Drawing.Size(105, 34)
    $cancelButton.Anchor = 'Bottom, Right'
    $form.Controls.Add($cancelButton)
    $form.CancelButton = $cancelButton

    $commitCurrent = {
        $index = [int]$state.CurrentIndex
        if ($state.Loading -or $index -lt 0 -or $index -ge $items.Count) { return }
        $items[$index].title = [string]$titleInput.Text
        $items[$index].hotkey = [string]$hotkeyInput.Text
        $items[$index].text = [string]$textInput.Text
        $caption = if ([string]::IsNullOrWhiteSpace($titleInput.Text)) { '(без названия)' } else { $titleInput.Text }
        if ([string]$list.Items[$index] -cne [string]$caption) { $list.Items[$index] = $caption }
    }

    $loadSelection = {
        $state.Loading = $true
        try {
            $index = [int]$state.CurrentIndex
            $enabled = ($index -ge 0 -and $index -lt $items.Count)
            $titleInput.Enabled = $enabled
            $hotkeyInput.Enabled = $enabled
            $textInput.Enabled = $enabled
            $deleteButton.Enabled = $enabled
            if ($enabled) {
                $titleInput.Text = [string]$items[$index].title
                $hotkeyInput.Text = [string]$items[$index].hotkey
                $textInput.Text = [string]$items[$index].text
            }
            else {
                $titleInput.Clear(); $hotkeyInput.Clear(); $textInput.Clear()
            }
        }
        finally { $state.Loading = $false }
    }

    $list.add_SelectedIndexChanged({
        if ($state.Loading) { return }
        & $commitCurrent
        $state.CurrentIndex = [int]$list.SelectedIndex
        & $loadSelection
    })
    $titleInput.add_TextChanged($commitCurrent)
    $hotkeyInput.add_TextChanged($commitCurrent)
    $textInput.add_TextChanged($commitCurrent)

    $addButton.add_Click({
        try {
            & $commitCurrent
            $used = @{}
            foreach ($item in $items) { $used[([string]$item.hotkey).Trim().ToUpperInvariant()] = $true }
            $candidate = $null
            foreach ($number in 1..9) {
                $option = "Ctrl+Alt+$number"
                if (-not $used.ContainsKey($option.ToUpperInvariant())) { $candidate = $option; break }
            }
            if ($null -eq $candidate) { throw 'Нет свободного сочетания Ctrl+Alt+1 — Ctrl+Alt+9.' }
            $newItem = [pscustomobject]@{
                id = "macro-$([Guid]::NewGuid().ToString('N'))"
                title = 'Новый макрос'
                hotkey = $candidate
                text = 'Новый текст'
            }
            [void]$items.Add($newItem)
            [void]$list.Items.Add($newItem.title)
            $list.SelectedIndex = $items.Count - 1
        }
        catch { [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, 'WHAM Quick Replies', 'OK', 'Error') | Out-Null }
    })

    $deleteButton.add_Click({
        try {
            $index = [int]$state.CurrentIndex
            if ($index -lt 0 -or $index -ge $items.Count) { return }
            if ($items.Count -eq 1) { throw 'Должен остаться хотя бы один макрос.' }
            $answer = [System.Windows.Forms.MessageBox]::Show("Удалить макрос '$($items[$index].title)'?", 'WHAM Quick Replies', 'YesNo', 'Question')
            if ($answer -ne [System.Windows.Forms.DialogResult]::Yes) { return }
            $items.RemoveAt($index)
            $list.Items.RemoveAt($index)
            $state.CurrentIndex = -1
            $list.SelectedIndex = [Math]::Min($index, $items.Count - 1)
        }
        catch { [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, 'WHAM Quick Replies', 'OK', 'Error') | Out-Null }
    })

    $saveButton.add_Click({
        try {
            & $commitCurrent
            $seenIds = @{}
            $seenHotkeys = @{}
            for ($index = 0; $index -lt $items.Count; $index++) {
                $item = $items[$index]
                if ([string]::IsNullOrWhiteSpace([string]$item.title) -or
                    [string]::IsNullOrWhiteSpace([string]$item.hotkey) -or
                    [string]::IsNullOrWhiteSpace([string]$item.text)) {
                    $list.SelectedIndex = $index
                    throw 'Заполните название, горячую клавишу и текст.'
                }
                $item.title = ([string]$item.title).Trim()
                $item.hotkey = ([string]$item.hotkey).Trim()
                [void](ConvertTo-HotkeyBinding -Hotkey $item.hotkey)
                $id = ([string]$item.id).Trim()
                $normalized = $item.hotkey.ToUpperInvariant()
                if ($seenIds.ContainsKey($id)) { throw "Повторяется id макроса: $id" }
                if ($seenHotkeys.ContainsKey($normalized)) {
                    $list.SelectedIndex = $index
                    throw "Сочетание '$($item.hotkey)' назначено нескольким макросам."
                }
                $seenIds[$id] = $true
                $seenHotkeys[$normalized] = $true
            }
            Write-MacrosVerified -Path $Path -Macros $items
            $form.DialogResult = [System.Windows.Forms.DialogResult]::OK
            $form.Close()
        }
        catch {
            [System.Windows.Forms.MessageBox]::Show("Не удалось сохранить макросы.`r`n`r`n$($_.Exception.Message)", 'WHAM Quick Replies', 'OK', 'Error') | Out-Null
        }
    })

    try {
        if ($items.Count -gt 0) { $list.SelectedIndex = 0 }
        return ($form.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK)
    }
    finally { $form.Dispose() }
}

function Wait-ModifierKeysReleased {
    $keys = @(0x10, 0x11, 0x12, 0x5B, 0x5C)
    $deadline = [DateTime]::UtcNow.AddMilliseconds(2000)
    while ([DateTime]::UtcNow -lt $deadline) {
        $pressed = $false
        foreach ($key in $keys) {
            if (([WhamHotkeyForm]::GetAsyncKeyState($key) -band 0x8000) -ne 0) { $pressed = $true; break }
        }
        if (-not $pressed) { return }
        Start-Sleep -Milliseconds 25
    }
}

function Set-ClipboardTextWithRetry {
    param([Parameter(Mandatory)][string]$Text)

    $lastError = $null
    foreach ($attempt in 1..10) {
        try {
            [System.Windows.Forms.Clipboard]::SetText($Text)
            return
        }
        catch { $lastError = $_; Start-Sleep -Milliseconds 80 }
    }
    throw "Не удалось записать текст в буфер обмена: $lastError"
}

function Invoke-SafePaste {
    param(
        [Parameter(Mandatory)][string]$Text,
        [IntPtr]$TargetWindow
    )

    $snapshot = $null
    try { $snapshot = [System.Windows.Forms.Clipboard]::GetDataObject() } catch { $snapshot = $null }

    Set-ClipboardTextWithRetry -Text $Text
    Wait-ModifierKeysReleased

    if ($TargetWindow -ne [IntPtr]::Zero -and [WhamHotkeyForm]::IsWindow($TargetWindow)) {
        [void][WhamHotkeyForm]::SetForegroundWindow($TargetWindow)
    }
    Start-Sleep -Milliseconds 180
    [WhamHotkeyForm]::SendCtrlV()

    Start-Sleep -Milliseconds 800
    try {
        if ([System.Windows.Forms.Clipboard]::ContainsText() -and [System.Windows.Forms.Clipboard]::GetText() -ceq $Text) {
            if ($null -eq $snapshot) { [System.Windows.Forms.Clipboard]::Clear() }
            else { [System.Windows.Forms.Clipboard]::SetDataObject($snapshot, $true) }
        }
    }
    catch {
        # Восстановление буфера — best effort.
    }
}

function Unregister-CurrentHotkeys {
    param(
        [Parameter(Mandatory)][WhamHotkeyForm]$Host,
        [Parameter(Mandatory)][pscustomobject]$State
    )

    foreach ($id in @($State.RegisteredIds)) { $Host.Unregister([int]$id) }
    $State.RegisteredIds.Clear()
    $State.MacroByRegistration.Clear()
}

function Register-HotkeysAtomic {
    param(
        [Parameter(Mandatory)][WhamHotkeyForm]$Host,
        [Parameter(Mandatory)][pscustomobject]$State,
        [Parameter(Mandatory)][object[]]$Macros
    )

    $newPlan = @(New-HotkeyPlan -Macros $Macros)
    $oldMacros = @($State.Macros)
    $oldPlan = if ($oldMacros.Count -gt 0) { @(New-HotkeyPlan -Macros $oldMacros) } else { @() }

    Unregister-CurrentHotkeys -Host $Host -State $State
    $newRegistered = New-Object System.Collections.ArrayList
    try {
        foreach ($entry in $newPlan) {
            $Host.Register([int]$entry.RegistrationId, [uint32]$entry.Binding.Modifiers, [uint32]$entry.Binding.Key)
            [void]$newRegistered.Add([int]$entry.RegistrationId)
            [void]$State.RegisteredIds.Add([int]$entry.RegistrationId)
            $State.MacroByRegistration[[int]$entry.RegistrationId] = [string]$entry.MacroId
        }
        $State.Macros = @($Macros)
    }
    catch {
        $registrationError = $_.Exception.Message
        foreach ($id in @($newRegistered)) { $Host.Unregister([int]$id) }
        $State.RegisteredIds.Clear()
        $State.MacroByRegistration.Clear()

        $restoreError = $null
        try {
            foreach ($entry in $oldPlan) {
                $Host.Register([int]$entry.RegistrationId, [uint32]$entry.Binding.Modifiers, [uint32]$entry.Binding.Key)
                [void]$State.RegisteredIds.Add([int]$entry.RegistrationId)
                $State.MacroByRegistration[[int]$entry.RegistrationId] = [string]$entry.MacroId
            }
            $State.Macros = @($oldMacros)
        }
        catch { $restoreError = $_.Exception.Message }

        if ($restoreError) {
            throw "Не удалось назначить новые сочетания: $registrationError`r`nТакже не удалось восстановить прежние сочетания: $restoreError"
        }
        throw "Не удалось назначить новые сочетания. Предыдущие сочетания восстановлены.`r`n$registrationError"
    }

    $hotkeys = @($Macros | ForEach-Object { [string]$_.hotkey })
    Write-WhamStatus -Status 'RUNNING' -Details @(
        "MACROS: $($Macros.Count)"
        "HOTKEYS: $($hotkeys -join ', ')"
        "SCRIPT: $PSCommandPath"
    )
}

if ($SelfTest) {
    $testMacros = @(Read-Macros -Path $MacrosPath)
    if ($testMacros.Count -lt 1) { throw 'Self-test: macros are missing.' }
    $plain = @(Get-TemplateVariables -Template 'Обычный текст без переменных')
    if ($plain.Count -ne 0) { throw 'Self-test: plain-text parsing failed.' }
    $variables = @(Get-TemplateVariables -Template 'Привет, {имя}. Заказ {номер}.')
    if (($variables -join ',') -ne 'имя,номер') { throw 'Self-test: variables failed.' }
    $binding = ConvertTo-HotkeyBinding -Hotkey 'Ctrl+Alt+F24'
    $testHost = New-Object WhamHotkeyForm
    try {
        $testHost.Register(9999, [uint32]$binding.Modifiers, [uint32]$binding.Key)
        $testHost.Unregister(9999)
    }
    finally { $testHost.Dispose() }
    Write-Output 'WHAM self-test passed.'
    exit 0
}

$mutex = New-Object System.Threading.Mutex($false, 'Local\WHAM.QuickReplies')
$ownsMutex = $false
try {
    try { $ownsMutex = $mutex.WaitOne(0, $false) }
    catch [System.Threading.AbandonedMutexException] { $ownsMutex = $true }

    if (-not $ownsMutex) {
        [System.Windows.Forms.MessageBox]::Show(
            'WHAM Quick Replies уже запущен. Найдите его значок рядом с часами.',
            'WHAM Quick Replies',
            'OK',
            'Information'
        ) | Out-Null
        exit 0
    }

    $hostForm = New-Object WhamHotkeyForm
    $notify = New-Object System.Windows.Forms.NotifyIcon
    $menu = New-Object System.Windows.Forms.ContextMenuStrip
    $appState = [pscustomobject]@{
        Macros = @()
        RegisteredIds = New-Object System.Collections.ArrayList
        MacroByRegistration = @{}
        Exiting = $false
    }

    try {
        Register-HotkeysAtomic -Host $hostForm -State $appState -Macros @(Read-Macros -Path $MacrosPath)

        $hostForm.add_HotkeyPressed({
            param([int]$registrationId)
            try {
                $targetWindow = [WhamHotkeyForm]::GetForegroundWindow()
                $latest = @(Read-Macros -Path $MacrosPath)
                $macroId = [string]$appState.MacroByRegistration[$registrationId]
                $macro = $latest | Where-Object { [string]$_.id -ceq $macroId } | Select-Object -First 1
                if ($null -eq $macro) { throw 'Макрос не найден. Перезагрузите сочетания через меню WHAM.' }
                $rendered = Show-TemplateDialog -Title ([string]$macro.title) -Template ([string]$macro.text)
                if ($null -eq $rendered) { return }
                Invoke-SafePaste -Text $rendered -TargetWindow $targetWindow
                Write-WhamStatus -Status 'RUNNING' -Details @(
                    "LAST_ACTION: inserted $([string]$macro.title)"
                    "LAST_HOTKEY: $([string]$macro.hotkey)"
                    "MACROS: $($appState.Macros.Count)"
                )
            }
            catch { Show-WhamError -Message "Не удалось вставить макрос.`r`n$($_.Exception.Message)" }
        })

        $statusItem = $menu.Items.Add("Готово: $($appState.Macros.Count) сочетаний активно")
        $statusItem.Enabled = $false

        $editorItem = $menu.Items.Add('Редактор макросов...')
        $editorItem.add_Click({
            try {
                $before = @(Read-Macros -Path $MacrosPath)
                if (Show-MacroEditor -Path $MacrosPath -Macros $before) {
                    try {
                        $after = @(Read-Macros -Path $MacrosPath)
                        Register-HotkeysAtomic -Host $hostForm -State $appState -Macros $after
                        $statusItem.Text = "Готово: $($appState.Macros.Count) сочетаний активно"
                        $notify.ShowBalloonTip(1800, 'WHAM Quick Replies', 'Макросы сохранены. Сочетания обновлены без перезапуска.', 'Info')
                    }
                    catch {
                        $backupPath = "$MacrosPath.bak"
                        if (Test-Path -LiteralPath $backupPath -PathType Leaf) {
                            Copy-Item -LiteralPath $backupPath -Destination $MacrosPath -Force
                        }
                        Register-HotkeysAtomic -Host $hostForm -State $appState -Macros $before
                        throw
                    }
                }
            }
            catch { Show-WhamError -Message "Не удалось обновить макросы.`r`n$($_.Exception.Message)" }
        })

        $reloadItem = $menu.Items.Add('Перезагрузить сочетания')
        $reloadItem.add_Click({
            try {
                Register-HotkeysAtomic -Host $hostForm -State $appState -Macros @(Read-Macros -Path $MacrosPath)
                $statusItem.Text = "Готово: $($appState.Macros.Count) сочетаний активно"
                $notify.ShowBalloonTip(1500, 'WHAM Quick Replies', 'Сочетания успешно перезагружены.', 'Info')
            }
            catch { Show-WhamError -Message $_.Exception.Message }
        })

        $openItem = $menu.Items.Add('Открыть macros.json')
        $openItem.add_Click({ Start-Process -FilePath 'notepad.exe' -ArgumentList ('"{0}"' -f $MacrosPath) })

        $openStatusItem = $menu.Items.Add('Открыть диагностику')
        $openStatusItem.add_Click({ Start-Process -FilePath 'notepad.exe' -ArgumentList ('"{0}"' -f $script:StatusPath) })

        [void]$menu.Items.Add('-')
        $exitItem = $menu.Items.Add('Выход')
        $exitItem.add_Click({
            $appState.Exiting = $true
            $hostForm.Close()
        })

        $notify.Icon = [System.Drawing.SystemIcons]::Information
        $notify.Text = 'WHAM Quick Replies — работает'
        $notify.ContextMenuStrip = $menu
        $notify.Visible = $true
        $notify.ShowBalloonTip(2200, 'WHAM Quick Replies', "$($appState.Macros.Count) сочетаний активны. Программа работает в фоне.", 'Info')

        [System.Windows.Forms.Application]::Run($hostForm)
    }
    finally {
        Write-WhamStatus -Status $(if ($appState.Exiting) { 'STOPPED_BY_USER' } else { 'STOPPED' }) -Details @("SCRIPT: $PSCommandPath")
        $notify.Visible = $false
        $notify.Dispose()
        $menu.Dispose()
        Unregister-CurrentHotkeys -Host $hostForm -State $appState
        $hostForm.Dispose()
    }
}
catch {
    if ($SelfTest) { throw }
    Write-WhamStatus -Status 'ERROR' -Details @("ERROR: $($_.Exception.Message)")
    Show-WhamError -Message $_.Exception.Message
    exit 1
}
finally {
    if ($ownsMutex) {
        try { $mutex.ReleaseMutex() } catch {}
    }
    $mutex.Dispose()
}
