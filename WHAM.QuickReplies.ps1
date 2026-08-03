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

function Write-WhamError {
    param([Parameter(Mandatory)][string]$Message)

    try {
        $line = '[{0}] {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message
        Add-Content -LiteralPath (Join-Path $PSScriptRoot 'WHAM-errors.log') -Value $line -Encoding UTF8
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

Add-Type -ReferencedAssemblies 'System.Windows.Forms.dll' -TypeDefinition @'
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

    [DllImport("user32.dll")]
    public static extern IntPtr GetForegroundWindow();

    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool SetForegroundWindow(IntPtr hWnd);

    [DllImport("user32.dll")]
    public static extern short GetAsyncKeyState(int virtualKey);

    public event Action<int> HotkeyPressed;

    public WhamHotkeyWindow()
    {
        CreateHandle(new CreateParams());
    }

    public void Register(int id, uint modifiers, uint key)
    {
        if (!RegisterHotKey(Handle, id, modifiers, key))
        {
            throw new InvalidOperationException(
                "RegisterHotKey failed. Win32 error: " + Marshal.GetLastWin32Error()
            );
        }
    }

    public void Unregister(int id)
    {
        UnregisterHotKey(Handle, id);
    }

    protected override void WndProc(ref Message message)
    {
        if (message.Msg == WM_HOTKEY && HotkeyPressed != null)
        {
            HotkeyPressed(message.WParam.ToInt32());
        }
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

    # MOD_NOREPEAT = 0x4000
    [uint32]$modifiers = 0x4000
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

    $state = [pscustomobject]@{
        Loading = $false
        CurrentIndex = -1
    }

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
    $hotkeyLabel.Text = 'Горячая клавиша: Alt+1, Alt+2 и т. д.'
    $hotkeyLabel.Location = New-Object Drawing.Point(252, 82)
    $hotkeyLabel.Size = New-Object Drawing.Size(430, 24)
    $form.Controls.Add($hotkeyLabel)

    $hotkeyInput = New-Object System.Windows.Forms.TextBox
    $hotkeyInput.Location = New-Object Drawing.Point(252, 107)
    $hotkeyInput.Size = New-Object Drawing.Size(545, 27)
    $hotkeyInput.Anchor = 'Top, Left, Right'
    $form.Controls.Add($hotkeyInput)

    $textLabel = New-Object System.Windows.Forms.Label
    $textLabel.Text = 'Текст макроса. Только выражения в {скобках} считаются переменными.'
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
        if ([string]$list.Items[$index] -cne [string]$caption) {
            $list.Items[$index] = $caption
        }
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
                $titleInput.Clear()
                $hotkeyInput.Clear()
                $textInput.Clear()
            }
        }
        finally {
            $state.Loading = $false
        }
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
            foreach ($item in $items) {
                $used[([string]$item.hotkey).Trim().ToUpperInvariant()] = $true
            }

            $candidate = $null
            foreach ($number in 1..9) {
                $option = "Alt+$number"
                if (-not $used.ContainsKey($option.ToUpperInvariant())) {
                    $candidate = $option
                    break
                }
            }
            if ($null -eq $candidate) {
                throw 'Нет свободного сочетания Alt+1 — Alt+9.'
            }

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
        catch {
            [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, 'WHAM Quick Replies', 'OK', 'Error') | Out-Null
        }
    })

    $deleteButton.add_Click({
        try {
            $index = [int]$state.CurrentIndex
            if ($index -lt 0 -or $index -ge $items.Count) { return }
            if ($items.Count -eq 1) {
                throw 'Должен остаться хотя бы один макрос.'
            }

            $answer = [System.Windows.Forms.MessageBox]::Show(
                "Удалить макрос '$($items[$index].title)'?",
                'WHAM Quick Replies',
                'YesNo',
                'Question'
            )
            if ($answer -ne [System.Windows.Forms.DialogResult]::Yes) { return }

            $items.RemoveAt($index)
            $list.Items.RemoveAt($index)
            $state.CurrentIndex = -1
            $list.SelectedIndex = [Math]::Min($index, $items.Count - 1)
        }
        catch {
            [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, 'WHAM Quick Replies', 'OK', 'Error') | Out-Null
        }
    })

    $saveButton.add_Click({
        try {
            & $commitCurrent

            $seen = @{}
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

                $normalized = $item.hotkey.ToUpperInvariant()
                if ($seen.ContainsKey($normalized)) {
                    $list.SelectedIndex = $index
                    throw "Сочетание '$($item.hotkey)' назначено нескольким макросам."
                }
                $seen[$normalized] = $true
            }

            Write-MacrosVerified -Path $Path -Macros $items
            [System.Windows.Forms.MessageBox]::Show(
                "Макросы сохранены и проверены.`r`n`r`n$Path",
                'WHAM Quick Replies',
                'OK',
                'Information'
            ) | Out-Null
            $form.DialogResult = [System.Windows.Forms.DialogResult]::OK
            $form.Close()
        }
        catch {
            [System.Windows.Forms.MessageBox]::Show(
                "Не удалось сохранить макросы.`r`n`r`n$($_.Exception.Message)",
                'WHAM Quick Replies',
                'OK',
                'Error'
            ) | Out-Null
        }
    })

    try {
        if ($items.Count -gt 0) { $list.SelectedIndex = 0 }
        return ($form.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK)
    }
    finally {
        $form.Dispose()
    }
}

function Wait-ModifierKeysReleased {
    $keys = @(0x10, 0x11, 0x12, 0x5B, 0x5C)
    $deadline = [DateTime]::UtcNow.AddMilliseconds(2000)

    while ([DateTime]::UtcNow -lt $deadline) {
        $pressed = $false
        foreach ($key in $keys) {
            if (([WhamHotkeyWindow]::GetAsyncKeyState($key) -band 0x8000) -ne 0) {
                $pressed = $true
                break
            }
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
        catch {
            $lastError = $_
            Start-Sleep -Milliseconds 80
        }
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

    if ($TargetWindow -ne [IntPtr]::Zero) {
        [void][WhamHotkeyWindow]::SetForegroundWindow($TargetWindow)
    }
    Start-Sleep -Milliseconds 150

    try {
        [System.Windows.Forms.SendKeys]::SendWait('^v')
    }
    catch {
        throw "Не удалось отправить Ctrl+V: $($_.Exception.Message)"
    }

    Start-Sleep -Milliseconds 800
    try {
        if ([System.Windows.Forms.Clipboard]::ContainsText() -and
            [System.Windows.Forms.Clipboard]::GetText() -ceq $Text) {
            if ($null -eq $snapshot) {
                [System.Windows.Forms.Clipboard]::Clear()
            }
            else {
                [System.Windows.Forms.Clipboard]::SetDataObject($snapshot, $true)
            }
        }
    }
    catch {
        # Восстановление буфера — только best effort.
    }
}

if ($SelfTest) {
    $testMacros = @(Read-Macros -Path $MacrosPath)
    if ($testMacros.Count -lt 1) { throw 'Self-test: macros are missing.' }

    $plain = @(Get-TemplateVariables -Template 'Обычный текст без переменных')
    if ($plain.Count -ne 0) { throw 'Self-test: plain-text parsing failed.' }

    $variables = @(Get-TemplateVariables -Template 'Привет, {имя}. Заказ {номер}.')
    if (($variables -join ',') -ne 'имя,номер') { throw 'Self-test: variables failed.' }

    $binding = ConvertTo-HotkeyBinding -Hotkey 'Alt+1'
    if (($binding.Modifiers -band 0x0001) -eq 0) { throw 'Self-test: Alt+1 failed.' }

    $testPath = Join-Path ([IO.Path]::GetTempPath()) ("wham-{0}.json" -f [Guid]::NewGuid().ToString('N'))
    try {
        $copy = @(ConvertTo-SerializableMacros -Macros $testMacros)
        $copy[0].text = 'Проверка сохранения'
        Write-MacrosVerified -Path $testPath -Macros $copy
        $saved = @(Read-Macros -Path $testPath)
        if ($saved[0].text -cne 'Проверка сохранения') { throw 'Self-test: persistence failed.' }
    }
    finally {
        Remove-Item -LiteralPath $testPath -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath "$testPath.tmp" -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath "$testPath.bak" -Force -ErrorAction SilentlyContinue
    }

    Write-Output 'WHAM self-test passed.'
    exit 0
}

$appState = [pscustomobject]@{ Restart = $false }

try {
    do {
        $appState.Restart = $false
        $macros = @(Read-Macros -Path $MacrosPath)
        $registered = New-Object 'System.Collections.Generic.List[int]'
        $macroByRegistration = @{}
        $window = New-Object WhamHotkeyWindow
        $notify = New-Object System.Windows.Forms.NotifyIcon
        $menu = New-Object System.Windows.Forms.ContextMenuStrip

        try {
            for ($index = 0; $index -lt $macros.Count; $index++) {
                $registrationId = $index + 1
                $binding = ConvertTo-HotkeyBinding -Hotkey ([string]$macros[$index].hotkey)
                try {
                    $window.Register($registrationId, $binding.Modifiers, $binding.Key)
                }
                catch {
                    throw "Не удалось назначить '$($macros[$index].hotkey)' макросу '$($macros[$index].title)'. Сочетание занято другой программой или уже запущенной копией WHAM."
                }
                $registered.Add($registrationId)
                $macroByRegistration[$registrationId] = [string]$macros[$index].id
            }

            $window.add_HotkeyPressed({
                param([int]$registrationId)
                try {
                    $targetWindow = [WhamHotkeyWindow]::GetForegroundWindow()
                    $latest = @(Read-Macros -Path $MacrosPath)
                    $macroId = [string]$macroByRegistration[$registrationId]
                    $macro = $latest | Where-Object { [string]$_.id -ceq $macroId } | Select-Object -First 1
                    if ($null -eq $macro) {
                        throw 'Макрос не найден. Используйте пункт «Перезагрузить макросы» в трее.'
                    }

                    $rendered = Show-TemplateDialog -Title ([string]$macro.title) -Template ([string]$macro.text)
                    if ($null -eq $rendered) { return }
                    Invoke-SafePaste -Text $rendered -TargetWindow $targetWindow
                }
                catch {
                    Show-WhamError -Message "Не удалось вставить макрос.`r`n$($_.Exception.Message)"
                }
            })

            $editorItem = $menu.Items.Add('Редактор макросов...')
            $editorItem.add_Click({
                try {
                    $latest = @(Read-Macros -Path $MacrosPath)
                    if (Show-MacroEditor -Path $MacrosPath -Macros $latest) {
                        $appState.Restart = $true
                        [System.Windows.Forms.Application]::ExitThread()
                    }
                }
                catch {
                    Show-WhamError -Message "Не удалось открыть редактор.`r`n$($_.Exception.Message)"
                }
            })

            $openItem = $menu.Items.Add('Открыть macros.json')
            $openItem.add_Click({
                Start-Process -FilePath 'notepad.exe' -ArgumentList ('"{0}"' -f $MacrosPath)
            })

            $reloadItem = $menu.Items.Add('Перезагрузить макросы')
            $reloadItem.add_Click({
                $appState.Restart = $true
                [System.Windows.Forms.Application]::ExitThread()
            })

            [void]$menu.Items.Add('-')
            $exitItem = $menu.Items.Add('Выход')
            $exitItem.add_Click({
                $appState.Restart = $false
                [System.Windows.Forms.Application]::ExitThread()
            })

            $notify.Icon = [System.Drawing.SystemIcons]::Information
            $notify.Text = 'WHAM Quick Replies'
            $notify.ContextMenuStrip = $menu
            $notify.Visible = $true
            $notify.ShowBalloonTip(2000, 'WHAM Quick Replies', "$($macros.Count) макросов активны.", 'Info')

            [System.Windows.Forms.Application]::Run()
        }
        finally {
            $notify.Visible = $false
            $notify.Dispose()
            $menu.Dispose()
            foreach ($id in $registered) { $window.Unregister($id) }
            $window.Dispose()
        }
    } while ($appState.Restart)
}
catch {
    if ($SelfTest) { throw }
    Show-WhamError -Message $_.Exception.Message
    exit 1
}
