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

function Show-FatalError {
    param([Parameter(Mandatory)][string]$Message)

    try {
        $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
        Add-Content -LiteralPath (Join-Path $PSScriptRoot 'WHAM-errors.log') -Encoding UTF8 -Value "[$timestamp] $Message"
    }
    catch {
        # Logging must never hide the original error.
    }

    [System.Windows.Forms.MessageBox]::Show(
        "$Message`r`n`r`nПодробности сохранены в WHAM-errors.log.",
        'WHAM Quick Replies — ошибка',
        'OK',
        'Error'
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
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool IsWindow(IntPtr hWnd);

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
                "Hotkey registration failed for id " + id + ". Win32 error: " + Marshal.GetLastWin32Error()
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
        throw "Не удалось прочитать macros.json. Проверьте кавычки и запятые. $($_.Exception.Message)"
    }

    $items = @(foreach ($item in $parsed) { $item })
    if ($items.Count -eq 0) {
        throw 'Должен существовать хотя бы один макрос.'
    }

    $ids = @{}
    $hotkeys = @{}
    foreach ($item in $items) {
        foreach ($property in 'id', 'title', 'hotkey', 'text') {
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
            throw "Горячая клавиша '$($item.hotkey)' назначена нескольким макросам."
        }

        $ids[$id] = $true
        $hotkeys[$hotkey] = $true
    }

    return $items
}

function ConvertTo-SerializableMacros {
    param([Parameter(Mandatory)][Collections.IEnumerable]$Macros)

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
        [Parameter(Mandatory)][Collections.IEnumerable]$Macros
    )

    $items = @(ConvertTo-SerializableMacros -Macros $Macros)
    if ($items.Count -eq 0) {
        throw 'Нельзя сохранить пустой список макросов.'
    }

    $directory = Split-Path -Parent $Path
    if ($directory -and -not (Test-Path -LiteralPath $directory -PathType Container)) {
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
    }

    $json = ConvertTo-Json -InputObject $items -Depth 4
    $tempPath = "$Path.tmp"
    $backupPath = "$Path.bak"

    try {
        [IO.File]::WriteAllText($tempPath, $json, [Text.UTF8Encoding]::new($true))

        if (Test-Path -LiteralPath $Path -PathType Leaf) {
            Copy-Item -LiteralPath $Path -Destination $backupPath -Force
        }

        Move-Item -LiteralPath $tempPath -Destination $Path -Force

        $saved = @(Read-Macros -Path $Path)
        $expectedJson = ConvertTo-Json -InputObject $items -Depth 4 -Compress
        $actualJson = ConvertTo-Json -InputObject (ConvertTo-SerializableMacros -Macros $saved) -Depth 4 -Compress
        if ($expectedJson -cne $actualJson) {
            throw 'Проверка после записи не прошла: содержимое файла отличается от текста в редакторе.'
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

    # MOD_NOREPEAT prevents repeated firing while the user holds the keys.
    $modifiers = [uint32]0x4000
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
                if ($keyName) {
                    throw "В сочетании должна быть ровно одна обычная клавиша: $Hotkey"
                }
                $keyName = $token
            }
        }
    }

    if (-not $keyName) {
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
    if ($variables.Count -eq 0) {
        return $Template
    }

    $form = [System.Windows.Forms.Form]::new()
    $form.Text = "WHAM — $Title"
    $form.StartPosition = 'CenterScreen'
    $form.FormBorderStyle = 'FixedDialog'
    $form.MinimizeBox = $false
    $form.MaximizeBox = $false
    $form.ShowInTaskbar = $true
    $form.Font = [Drawing.Font]::new('Segoe UI', 10)

    $inputs = @{}
    $top = 16
    foreach ($name in $variables) {
        $label = [System.Windows.Forms.Label]::new()
        $label.Text = $name.Replace('_', ' ')
        $label.Location = [Drawing.Point]::new(16, ($top + 5))
        $label.Size = [Drawing.Size]::new(150, 25)
        $form.Controls.Add($label)

        $input = [System.Windows.Forms.TextBox]::new()
        $input.Location = [Drawing.Point]::new(170, $top)
        $input.Size = [Drawing.Size]::new(370, 27)
        $form.Controls.Add($input)
        $inputs[$name] = $input
        $top += 42
    }

    $previewLabel = [System.Windows.Forms.Label]::new()
    $previewLabel.Text = 'Предпросмотр'
    $previewLabel.Location = [Drawing.Point]::new(16, $top)
    $previewLabel.Size = [Drawing.Size]::new(150, 24)
    $form.Controls.Add($previewLabel)
    $top += 25

    $preview = [System.Windows.Forms.TextBox]::new()
    $preview.Location = [Drawing.Point]::new(16, $top)
    $preview.Size = [Drawing.Size]::new(524, 110)
    $preview.Multiline = $true
    $preview.ScrollBars = 'Vertical'
    $preview.ReadOnly = $true
    $form.Controls.Add($preview)
    $top += 122

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
        foreach ($name in $variables) {
            $values[$name] = $inputs[$name].Text
        }
        $preview.Text = Expand-Template -Template $Template -Values $values
    }

    foreach ($input in $inputs.Values) {
        $input.add_TextChanged({ & $refreshPreview })
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

    $items = [Collections.ArrayList]::new()
    foreach ($macro in $Macros) {
        [void]$items.Add([pscustomobject]@{
            id = [string]$macro.id
            title = [string]$macro.title
            hotkey = [string]$macro.hotkey
            text = [string]$macro.text
        })
    }

    # A shared object is essential here. PowerShell delegate handlers use child
    # scopes, so assigning plain $currentIndex/$loading variables loses changes.
    $state = [pscustomobject]@{
        Loading = $false
        CurrentIndex = -1
    }

    $form = [System.Windows.Forms.Form]::new()
    $form.Text = 'WHAM — редактор макросов'
    $form.StartPosition = 'CenterScreen'
    $form.MinimumSize = [Drawing.Size]::new(780, 520)
    $form.ClientSize = [Drawing.Size]::new(820, 540)
    $form.Font = [Drawing.Font]::new('Segoe UI', 10)

    $list = [System.Windows.Forms.ListBox]::new()
    $list.Location = [Drawing.Point]::new(16, 16)
    $list.Size = [Drawing.Size]::new(220, 450)
    $list.Anchor = 'Top, Bottom, Left'
    foreach ($item in $items) {
        [void]$list.Items.Add($item.title)
    }
    $form.Controls.Add($list)

    $titleLabel = [System.Windows.Forms.Label]::new()
    $titleLabel.Text = 'Название'
    $titleLabel.Location = [Drawing.Point]::new(252, 18)
    $titleLabel.Size = [Drawing.Size]::new(100, 24)
    $form.Controls.Add($titleLabel)

    $titleInput = [System.Windows.Forms.TextBox]::new()
    $titleInput.Location = [Drawing.Point]::new(252, 43)
    $titleInput.Size = [Drawing.Size]::new(545, 27)
    $titleInput.Anchor = 'Top, Left, Right'
    $form.Controls.Add($titleInput)

    $hotkeyLabel = [System.Windows.Forms.Label]::new()
    $hotkeyLabel.Text = 'Горячая клавиша, например Alt+1 или Ctrl+Alt+1'
    $hotkeyLabel.Location = [Drawing.Point]::new(252, 82)
    $hotkeyLabel.Size = [Drawing.Size]::new(430, 24)
    $form.Controls.Add($hotkeyLabel)

    $hotkeyInput = [System.Windows.Forms.TextBox]::new()
    $hotkeyInput.Location = [Drawing.Point]::new(252, 107)
    $hotkeyInput.Size = [Drawing.Size]::new(545, 27)
    $hotkeyInput.Anchor = 'Top, Left, Right'
    $form.Controls.Add($hotkeyInput)

    $textLabel = [System.Windows.Forms.Label]::new()
    $textLabel.Text = 'Текст макроса. Выражения в {скобках} запрашиваются перед вставкой.'
    $textLabel.Location = [Drawing.Point]::new(252, 146)
    $textLabel.Size = [Drawing.Size]::new(530, 24)
    $form.Controls.Add($textLabel)

    $textInput = [System.Windows.Forms.TextBox]::new()
    $textInput.Location = [Drawing.Point]::new(252, 171)
    $textInput.Size = [Drawing.Size]::new(545, 295)
    $textInput.Multiline = $true
    $textInput.AcceptsReturn = $true
    $textInput.ScrollBars = 'Vertical'
    $textInput.Anchor = 'Top, Bottom, Left, Right'
    $form.Controls.Add($textInput)

    $addButton = [System.Windows.Forms.Button]::new()
    $addButton.Text = 'Добавить'
    $addButton.Location = [Drawing.Point]::new(16, 482)
    $addButton.Size = [Drawing.Size]::new(105, 34)
    $addButton.Anchor = 'Bottom, Left'
    $form.Controls.Add($addButton)

    $deleteButton = [System.Windows.Forms.Button]::new()
    $deleteButton.Text = 'Удалить'
    $deleteButton.Location = [Drawing.Point]::new(131, 482)
    $deleteButton.Size = [Drawing.Size]::new(105, 34)
    $deleteButton.Anchor = 'Bottom, Left'
    $form.Controls.Add($deleteButton)

    $saveButton = [System.Windows.Forms.Button]::new()
    $saveButton.Text = 'Сохранить'
    $saveButton.Location = [Drawing.Point]::new(577, 482)
    $saveButton.Size = [Drawing.Size]::new(105, 34)
    $saveButton.Anchor = 'Bottom, Right'
    $form.Controls.Add($saveButton)

    $cancelButton = [System.Windows.Forms.Button]::new()
    $cancelButton.Text = 'Отмена'
    $cancelButton.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    $cancelButton.Location = [Drawing.Point]::new(692, 482)
    $cancelButton.Size = [Drawing.Size]::new(105, 34)
    $cancelButton.Anchor = 'Bottom, Right'
    $form.Controls.Add($cancelButton)
    $form.CancelButton = $cancelButton

    $commitCurrent = {
        $index = [int]$state.CurrentIndex
        if ($state.Loading -or $index -lt 0 -or $index -ge $items.Count) {
            return
        }

        $items[$index].title = [string]$titleInput.Text
        $items[$index].hotkey = [string]$hotkeyInput.Text
        $items[$index].text = [string]$textInput.Text

        $caption = if ([string]::IsNullOrWhiteSpace($titleInput.Text)) {
            '(без названия)'
        }
        else {
            $titleInput.Text
        }
        if ([string]$list.Items[$index] -cne $caption) {
            $list.Items[$index] = $caption
        }
    }

    $list.add_SelectedIndexChanged({
        if ($state.Loading) { return }

        $state.CurrentIndex = [int]$list.SelectedIndex
        $state.Loading = $true
        try {
            $index = [int]$state.CurrentIndex
            $enabled = $index -ge 0 -and $index -lt $items.Count
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
    })

    $titleInput.add_TextChanged({ & $commitCurrent })
    $hotkeyInput.add_TextChanged({ & $commitCurrent })
    $textInput.add_TextChanged({ & $commitCurrent })

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
            if (-not $candidate) {
                foreach ($number in 1..24) {
                    $option = "Ctrl+Alt+F$number"
                    if (-not $used.ContainsKey($option.ToUpperInvariant())) {
                        $candidate = $option
                        break
                    }
                }
            }
            if (-not $candidate) {
                throw 'Не удалось подобрать свободное сочетание для нового макроса.'
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
            $titleInput.SelectAll()
            $titleInput.Focus() | Out-Null
        }
        catch {
            [System.Windows.Forms.MessageBox]::Show(
                $_.Exception.Message,
                'WHAM Quick Replies',
                'OK',
                'Error'
            ) | Out-Null
        }
    })

    $deleteButton.add_Click({
        try {
            $index = [int]$state.CurrentIndex
            if ($index -lt 0 -or $index -ge $items.Count) { return }
            if ($items.Count -eq 1) {
                [System.Windows.Forms.MessageBox]::Show(
                    'Должен остаться хотя бы один макрос.',
                    'WHAM Quick Replies',
                    'OK',
                    'Warning'
                ) | Out-Null
                return
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
            [System.Windows.Forms.MessageBox]::Show(
                $_.Exception.Message,
                'WHAM Quick Replies',
                'OK',
                'Error'
            ) | Out-Null
        }
    })

    $saveButton.add_Click({
        try {
            # Explicitly copy the visible controls before validation. This is a
            # second safeguard even if a TextChanged event was skipped by WinForms.
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
                $normalizedHotkey = $item.hotkey.ToUpperInvariant()
                if ($seenIds.ContainsKey($id)) {
                    throw "Повторяется id макроса: $id"
                }
                if ($seenHotkeys.ContainsKey($normalizedHotkey)) {
                    $list.SelectedIndex = $index
                    throw "Горячая клавиша '$($item.hotkey)' назначена нескольким макросам."
                }
                $seenIds[$id] = $true
                $seenHotkeys[$normalizedHotkey] = $true
            }

            Write-MacrosVerified -Path $Path -Macros $items

            [System.Windows.Forms.MessageBox]::Show(
                "Макросы сохранены и проверены.`r`n`r`nФайл:`r`n$Path`r`n`r`nWHAM сейчас перезапустится.",
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
        if ($items.Count -gt 0) {
            $list.SelectedIndex = 0
        }
        return $form.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK
    }
    finally {
        $form.Dispose()
    }
}

function Wait-ModifierKeysReleased {
    param([int]$TimeoutMilliseconds = 1500)

    $virtualKeys = @(0x10, 0x11, 0x12, 0x5B, 0x5C) # Shift, Ctrl, Alt, Win
    $deadline = [DateTime]::UtcNow.AddMilliseconds($TimeoutMilliseconds)

    while ([DateTime]::UtcNow -lt $deadline) {
        $pressed = $false
        foreach ($virtualKey in $virtualKeys) {
            if (([WhamHotkeyWindow]::GetAsyncKeyState($virtualKey) -band 0x8000) -ne 0) {
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
        # Clipboard ownership may change at any time; restoration is best-effort.
    }
}

function Invoke-SafePaste {
    param(
        [Parameter(Mandatory)][string]$Text,
        [IntPtr]$TargetWindow
    )

    $snapshot = $null
    try {
        $snapshot = [System.Windows.Forms.Clipboard]::GetDataObject()
    }
    catch {
        $snapshot = $null
    }

    Set-ClipboardTextWithRetry -Text $Text

    if ($TargetWindow -ne [IntPtr]::Zero -and [WhamHotkeyWindow]::IsWindow($TargetWindow)) {
        [void][WhamHotkeyWindow]::SetForegroundWindow($TargetWindow)
    }

    Wait-ModifierKeysReleased
    Start-Sleep -Milliseconds 120

    try {
        [System.Windows.Forms.SendKeys]::SendWait('^v')
    }
    catch {
        Restore-ClipboardSnapshot -Snapshot $snapshot -ExpectedText $Text
        throw
    }

    Start-Sleep -Milliseconds 650
    Restore-ClipboardSnapshot -Snapshot $snapshot -ExpectedText $Text
}

function Find-MacroById {
    param(
        [Parameter(Mandatory)][object[]]$Macros,
        [Parameter(Mandatory)][string]$Id
    )

    foreach ($macro in $Macros) {
        if ([string]$macro.id -ceq $Id) {
            return $macro
        }
    }
    return $null
}

if ($SelfTest) {
    $testMacros = @(Read-Macros -Path $MacrosPath)
    if ($testMacros.Count -ne 5) {
        throw "Self-test expected 5 macros, got $($testMacros.Count)."
    }

    $variables = @(Get-TemplateVariables -Template 'Добрый день, {имя}! Заказ №{номер}.')
    if (($variables -join ',') -ne 'имя,номер') {
        throw 'Variable extraction self-test failed.'
    }

    $plainVariables = @(Get-TemplateVariables -Template 'Текст без переменных')
    if ($plainVariables.Count -ne 0) {
        throw 'Plain-text macro self-test failed.'
    }

    $altBinding = ConvertTo-HotkeyBinding -Hotkey 'Alt+1'
    if (($altBinding.Modifiers -band 0x0001) -eq 0) {
        throw 'Alt+1 parsing self-test failed.'
    }

    $roundTripPath = Join-Path ([IO.Path]::GetTempPath()) "wham-$([Guid]::NewGuid().ToString('N')).json"
    try {
        $copy = @(ConvertTo-SerializableMacros -Macros $testMacros)
        $copy[0].text = 'Проверка сохранения без переменных'
        Write-MacrosVerified -Path $roundTripPath -Macros $copy
        $roundTrip = @(Read-Macros -Path $roundTripPath)
        if ($roundTrip[0].text -cne 'Проверка сохранения без переменных') {
            throw 'Verified macro storage self-test failed.'
        }
    }
    finally {
        Remove-Item -LiteralPath $roundTripPath -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath "$roundTripPath.tmp" -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath "$roundTripPath.bak" -Force -ErrorAction SilentlyContinue
    }

    $binding = ConvertTo-HotkeyBinding -Hotkey 'Ctrl+Alt+F24'
    $testWindow = [WhamHotkeyWindow]::new()
    try {
        $testWindow.Register(9001, $binding.Modifiers, $binding.Key)
        $testWindow.Unregister(9001)
    }
    finally {
        $testWindow.Dispose()
    }

    Write-Output 'WHAM Windows self-test passed.'
    exit 0
}

$createdNew = $false
$mutex = [Threading.Mutex]::new($true, 'Local\WHAM.QuickReplies', [ref]$createdNew)
if (-not $createdNew) {
    [System.Windows.Forms.MessageBox]::Show(
        'WHAM Quick Replies уже запущен. Найдите его значок рядом с часами.',
        'WHAM Quick Replies',
        'OK',
        'Information'
    ) | Out-Null
    $mutex.Dispose()
    exit 0
}

$macros = @(Read-Macros -Path $MacrosPath)
$macroIdsByRegistration = @{}
$registeredIds = [Collections.Generic.List[int]]::new()
$script:restartRequested = $false
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
            throw "Не удалось назначить '$($macros[$index].hotkey)' макросу '$($macros[$index].title)'. Сочетание занято Windows или другой программой. $($_.Exception.Message)"
        }

        $registeredIds.Add($registrationId)
        $macroIdsByRegistration[$registrationId] = [string]$macros[$index].id
    }

    $hotkeyWindow.add_HotkeyPressed({
        param([int]$registrationId)

        try {
            $targetWindow = [WhamHotkeyWindow]::GetForegroundWindow()
            $latestMacros = @(Read-Macros -Path $MacrosPath)
            $macroId = [string]$macroIdsByRegistration[$registrationId]
            $macro = Find-MacroById -Macros $latestMacros -Id $macroId
            if ($null -eq $macro) {
                throw "Макрос '$macroId' не найден. Перезапустите WHAM."
            }

            $rendered = Show-TemplateDialog -Title ([string]$macro.title) -Template ([string]$macro.text)
            if ($null -eq $rendered) { return }
            Invoke-SafePaste -Text $rendered -TargetWindow $targetWindow
        }
        catch {
            [System.Windows.Forms.MessageBox]::Show(
                "WHAM не смог вставить макрос.`r`n`r`n$($_.Exception.Message)",
                'WHAM Quick Replies',
                'OK',
                'Error'
            ) | Out-Null
        }
    })

    $editMacros = $menu.Items.Add('Редактор макросов...')
    $editMacros.add_Click({
        try {
            $latestMacros = @(Read-Macros -Path $MacrosPath)
            if (Show-MacroEditor -Path $MacrosPath -Macros $latestMacros) {
                $script:restartRequested = $true
                [System.Windows.Forms.Application]::Exit()
            }
        }
        catch {
            [System.Windows.Forms.MessageBox]::Show(
                "Не удалось открыть редактор.`r`n`r`n$($_.Exception.Message)",
                'WHAM Quick Replies',
                'OK',
                'Error'
            ) | Out-Null
        }
    })

    $openMacros = $menu.Items.Add('Открыть macros.json')
    $openMacros.add_Click({
        Start-Process -FilePath 'notepad.exe' -ArgumentList ('"{0}"' -f $MacrosPath)
    })

    $restartItem = $menu.Items.Add('Перезапустить WHAM')
    $restartItem.add_Click({
        $script:restartRequested = $true
        [System.Windows.Forms.Application]::Exit()
    })

    $menu.Items.Add('-') | Out-Null
    $exitItem = $menu.Items.Add('Выход')
    $exitItem.add_Click({
        [System.Windows.Forms.Application]::Exit()
    })

    $notifyIcon.Icon = [System.Drawing.SystemIcons]::Information
    $notifyIcon.Text = 'WHAM Quick Replies'
    $notifyIcon.ContextMenuStrip = $menu
    $notifyIcon.Visible = $true
    $notifyIcon.ShowBalloonTip(
        2500,
        'WHAM Quick Replies',
        "$($macros.Count) макросов активны. Редактор доступен по правому клику.",
        'Info'
    )

    [System.Windows.Forms.Application]::Run()
}
catch {
    Show-FatalError -Message $_.Exception.Message
}
finally {
    $notifyIcon.Visible = $false
    $notifyIcon.Dispose()
    $menu.Dispose()

    foreach ($id in $registeredIds) {
        $hotkeyWindow.Unregister($id)
    }
    $hotkeyWindow.Dispose()

    try {
        $mutex.ReleaseMutex()
    }
    catch {
        # The mutex may not be owned after an early startup failure.
    }
    $mutex.Dispose()
}

if ($script:restartRequested) {
    $restartArguments = "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -STA -File `"$PSCommandPath`" -MacrosPath `"$MacrosPath`""
    Start-Process -FilePath 'powershell.exe' -ArgumentList $restartArguments
}
