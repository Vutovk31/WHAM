#requires -version 5.1

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
$path = Join-Path $root 'WHAM.QuickReplies.ps1'
if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
    throw "WHAM script not found: $path"
}

$content = [IO.File]::ReadAllText($path)
if ($content.Contains('function Format-EditorHotkeySelection')) {
    Write-Output 'Hotkey dropdown patch is already applied.'
    exit 0
}

$editorReplacement = @'
function Get-EditorHotkeyParts {
    param([Parameter(Mandatory)][string]$Hotkey)

    $modifiers = New-Object 'System.Collections.Generic.List[string]'
    $keyName = $null
    foreach ($part in ($Hotkey -split '\+')) {
        $token = $part.Trim()
        if ([string]::IsNullOrWhiteSpace($token)) { continue }
        switch ($token.ToUpperInvariant()) {
            'CTRL'    { if (-not $modifiers.Contains('Ctrl')) { $modifiers.Add('Ctrl') } }
            'CONTROL' { if (-not $modifiers.Contains('Ctrl')) { $modifiers.Add('Ctrl') } }
            'ALT'     { if (-not $modifiers.Contains('Alt')) { $modifiers.Add('Alt') } }
            'SHIFT'   { if (-not $modifiers.Contains('Shift')) { $modifiers.Add('Shift') } }
            'WIN'     { if (-not $modifiers.Contains('Win')) { $modifiers.Add('Win') } }
            default {
                if ($null -ne $keyName) {
                    throw "В сочетании должна быть одна основная клавиша: $Hotkey"
                }
                $keyName = $token
            }
        }
    }

    if ($modifiers.Count -eq 0) { throw 'Выберите хотя бы один модификатор: Ctrl, Alt, Shift или Win.' }
    if ([string]::IsNullOrWhiteSpace($keyName)) { throw "В сочетании отсутствует основная клавиша: $Hotkey" }
    if ($keyName -match '^D([0-9])$') { $keyName = $Matches[1] }

    $ordered = New-Object 'System.Collections.Generic.List[string]'
    foreach ($name in @('Ctrl', 'Alt', 'Shift', 'Win')) {
        if ($modifiers.Contains($name)) { $ordered.Add($name) }
    }
    return [pscustomobject]@{ Modifiers = $ordered.ToArray(); Key = $keyName }
}

function Format-EditorHotkeySelection {
    param(
        [Parameter(Mandatory)][string[]]$Modifiers,
        [Parameter(Mandatory)][string]$Key
    )

    $selected = @($Modifiers | Where-Object { $_ -and $_ -ne '(нет)' } | Select-Object -Unique)
    $ordered = New-Object 'System.Collections.Generic.List[string]'
    foreach ($name in @('Ctrl', 'Alt', 'Shift', 'Win')) {
        if ($selected -contains $name) { $ordered.Add($name) }
    }
    if ($ordered.Count -eq 0) { throw 'Выберите хотя бы один модификатор.' }
    if ([string]::IsNullOrWhiteSpace($Key)) { throw 'Выберите основную клавишу.' }
    return (($ordered.ToArray() + $Key.Trim()) -join '+')
}

function Show-MacroEditor {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][object[]]$Macros
    )

    $modifierOptions = @('(нет)', 'Ctrl', 'Alt', 'Shift', 'Win')
    $keyOptions = @(
        '1','2','3','4','5','6','7','8','9','0',
        'F1','F2','F3','F4','F5','F6','F7','F8','F9','F10','F11','F12',
        'A','B','C','D','E','F','G','H','I','J','K','L','M','N','O','P','Q','R','S','T','U','V','W','X','Y','Z',
        'Tab','Space','Enter','Escape','Back','Insert','Delete','Home','End','PageUp','PageDown',
        'NumPad0','NumPad1','NumPad2','NumPad3','NumPad4','NumPad5','NumPad6','NumPad7','NumPad8','NumPad9',
        'Add','Subtract','Multiply','Divide'
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
    $form.FormBorderStyle = 'FixedDialog'
    $form.MaximizeBox = $false
    $form.MinimizeBox = $false
    $form.ClientSize = New-Object Drawing.Size(860, 570)
    $form.Font = New-Object Drawing.Font('Segoe UI', 10)

    $list = New-Object System.Windows.Forms.ListBox
    $list.Location = New-Object Drawing.Point(16, 16)
    $list.Size = New-Object Drawing.Size(220, 482)
    foreach ($item in $items) { [void]$list.Items.Add($item.title) }
    $form.Controls.Add($list)

    $titleLabel = New-Object System.Windows.Forms.Label
    $titleLabel.Text = 'Название макроса'
    $titleLabel.Location = New-Object Drawing.Point(252, 18)
    $titleLabel.Size = New-Object Drawing.Size(180, 24)
    $form.Controls.Add($titleLabel)

    $titleInput = New-Object System.Windows.Forms.TextBox
    $titleInput.Location = New-Object Drawing.Point(252, 43)
    $titleInput.Size = New-Object Drawing.Size(590, 27)
    $form.Controls.Add($titleInput)

    $hotkeyGroup = New-Object System.Windows.Forms.GroupBox
    $hotkeyGroup.Text = 'Горячая клавиша'
    $hotkeyGroup.Location = New-Object Drawing.Point(252, 82)
    $hotkeyGroup.Size = New-Object Drawing.Size(590, 112)
    $form.Controls.Add($hotkeyGroup)

    $comboLabels = @('Модификатор 1', 'Модификатор 2', 'Модификатор 3', 'Клавиша')
    $comboX = @(14, 154, 294, 434)
    for ($i = 0; $i -lt 4; $i++) {
        $label = New-Object System.Windows.Forms.Label
        $label.Text = $comboLabels[$i]
        $label.Location = New-Object Drawing.Point($comboX[$i], 24)
        $label.Size = New-Object Drawing.Size(130, 20)
        $hotkeyGroup.Controls.Add($label)
    }

    $modifier1 = New-Object System.Windows.Forms.ComboBox
    $modifier2 = New-Object System.Windows.Forms.ComboBox
    $modifier3 = New-Object System.Windows.Forms.ComboBox
    $keyInput = New-Object System.Windows.Forms.ComboBox
    $modifierCombos = @($modifier1, $modifier2, $modifier3)
    for ($i = 0; $i -lt 3; $i++) {
        $combo = $modifierCombos[$i]
        $combo.DropDownStyle = 'DropDownList'
        $combo.Location = New-Object Drawing.Point($comboX[$i], 47)
        $combo.Size = New-Object Drawing.Size(128, 27)
        foreach ($option in $modifierOptions) { [void]$combo.Items.Add($option) }
        $combo.SelectedIndex = 0
        $hotkeyGroup.Controls.Add($combo)
    }

    $keyInput.DropDownStyle = 'DropDownList'
    $keyInput.Location = New-Object Drawing.Point($comboX[3], 47)
    $keyInput.Size = New-Object Drawing.Size(140, 27)
    foreach ($option in $keyOptions) { [void]$keyInput.Items.Add($option) }
    $hotkeyGroup.Controls.Add($keyInput)

    $hotkeyPreview = New-Object System.Windows.Forms.Label
    $hotkeyPreview.Text = 'Сочетание: —'
    $hotkeyPreview.Location = New-Object Drawing.Point(14, 82)
    $hotkeyPreview.Size = New-Object Drawing.Size(550, 22)
    $hotkeyGroup.Controls.Add($hotkeyPreview)

    $textLabel = New-Object System.Windows.Forms.Label
    $textLabel.Text = 'Текст макроса. Поля в {скобках} будут запрошены перед вставкой.'
    $textLabel.Location = New-Object Drawing.Point(252, 207)
    $textLabel.Size = New-Object Drawing.Size(590, 24)
    $form.Controls.Add($textLabel)

    $textInput = New-Object System.Windows.Forms.TextBox
    $textInput.Location = New-Object Drawing.Point(252, 232)
    $textInput.Size = New-Object Drawing.Size(590, 266)
    $textInput.Multiline = $true
    $textInput.AcceptsReturn = $true
    $textInput.ScrollBars = 'Vertical'
    $form.Controls.Add($textInput)

    $addButton = New-Object System.Windows.Forms.Button
    $addButton.Text = 'Добавить'
    $addButton.Location = New-Object Drawing.Point(16, 516)
    $addButton.Size = New-Object Drawing.Size(105, 34)
    $form.Controls.Add($addButton)

    $deleteButton = New-Object System.Windows.Forms.Button
    $deleteButton.Text = 'Удалить'
    $deleteButton.Location = New-Object Drawing.Point(131, 516)
    $deleteButton.Size = New-Object Drawing.Size(105, 34)
    $form.Controls.Add($deleteButton)

    $saveButton = New-Object System.Windows.Forms.Button
    $saveButton.Text = 'Сохранить'
    $saveButton.Location = New-Object Drawing.Point(622, 516)
    $saveButton.Size = New-Object Drawing.Size(105, 34)
    $form.Controls.Add($saveButton)

    $cancelButton = New-Object System.Windows.Forms.Button
    $cancelButton.Text = 'Отмена'
    $cancelButton.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    $cancelButton.Location = New-Object Drawing.Point(737, 516)
    $cancelButton.Size = New-Object Drawing.Size(105, 34)
    $form.Controls.Add($cancelButton)
    $form.CancelButton = $cancelButton

    $getSelectedHotkey = {
        $mods = @($modifier1.SelectedItem, $modifier2.SelectedItem, $modifier3.SelectedItem) |
            ForEach-Object { [string]$_ } |
            Where-Object { $_ -and $_ -ne '(нет)' }
        return (Format-EditorHotkeySelection -Modifiers $mods -Key ([string]$keyInput.SelectedItem))
    }

    $refreshPreview = {
        if ($state.Loading) { return }
        try { $hotkeyPreview.Text = "Сочетание: $(& $getSelectedHotkey)" }
        catch { $hotkeyPreview.Text = 'Сочетание: выберите модификатор и клавишу' }
    }

    $commitCurrent = {
        $index = [int]$state.CurrentIndex
        if ($state.Loading -or $index -lt 0 -or $index -ge $items.Count) { return }
        $items[$index].title = [string]$titleInput.Text
        $items[$index].text = [string]$textInput.Text
        try { $items[$index].hotkey = & $getSelectedHotkey } catch {}
        $caption = if ([string]::IsNullOrWhiteSpace($titleInput.Text)) { '(без названия)' } else { $titleInput.Text }
        if ([string]$list.Items[$index] -cne [string]$caption) { $list.Items[$index] = $caption }
        & $refreshPreview
    }

    $setComboValue = {
        param($Combo, [string]$Value)
        $index = $Combo.Items.IndexOf($Value)
        if ($index -lt 0) { $index = 0 }
        $Combo.SelectedIndex = $index
    }

    $loadSelection = {
        $state.Loading = $true
        try {
            $index = [int]$state.CurrentIndex
            $enabled = ($index -ge 0 -and $index -lt $items.Count)
            $titleInput.Enabled = $enabled
            $textInput.Enabled = $enabled
            $deleteButton.Enabled = $enabled
            foreach ($combo in ($modifierCombos + @($keyInput))) { $combo.Enabled = $enabled }
            if ($enabled) {
                $titleInput.Text = [string]$items[$index].title
                $textInput.Text = [string]$items[$index].text
                $parts = Get-EditorHotkeyParts -Hotkey ([string]$items[$index].hotkey)
                $mods = @($parts.Modifiers)
                if ($mods.Count -gt 3) { throw 'Редактор поддерживает до трёх модификаторов одновременно.' }
                & $setComboValue $modifier1 $(if ($mods.Count -gt 0) { $mods[0] } else { '(нет)' })
                & $setComboValue $modifier2 $(if ($mods.Count -gt 1) { $mods[1] } else { '(нет)' })
                & $setComboValue $modifier3 $(if ($mods.Count -gt 2) { $mods[2] } else { '(нет)' })
                $keyIndex = $keyInput.Items.IndexOf([string]$parts.Key)
                if ($keyIndex -lt 0) { throw "Клавиша '$($parts.Key)' отсутствует в списке редактора." }
                $keyInput.SelectedIndex = $keyIndex
                $hotkeyPreview.Text = "Сочетание: $($items[$index].hotkey)"
            }
            else {
                $titleInput.Clear(); $textInput.Clear()
                foreach ($combo in $modifierCombos) { $combo.SelectedIndex = 0 }
                $keyInput.SelectedIndex = -1
                $hotkeyPreview.Text = 'Сочетание: —'
            }
        }
        finally { $state.Loading = $false }
    }

    $list.add_SelectedIndexChanged({
        if ($state.Loading) { return }
        & $commitCurrent
        $state.CurrentIndex = [int]$list.SelectedIndex
        try { & $loadSelection }
        catch { [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, 'WHAM Quick Replies', 'OK', 'Error') | Out-Null }
    })
    $titleInput.add_TextChanged($commitCurrent)
    $textInput.add_TextChanged($commitCurrent)
    foreach ($combo in ($modifierCombos + @($keyInput))) { $combo.add_SelectedIndexChanged({ & $commitCurrent }) }

    $addButton.add_Click({
        try {
            & $commitCurrent
            $used = @{}
            foreach ($item in $items) { $used[([string]$item.hotkey).Trim().ToUpperInvariant()] = $true }
            $candidate = $null
            foreach ($prefix in @('Ctrl+Alt', 'Alt', 'Ctrl+Shift', 'Ctrl')) {
                foreach ($key in @('1','2','3','4','5','6','7','8','9','0','F1','F2','F3','F4','F5','F6','F7','F8','F9','F10','F11','F12')) {
                    $option = "$prefix+$key"
                    if (-not $used.ContainsKey($option.ToUpperInvariant())) { $candidate = $option; break }
                }
                if ($candidate) { break }
            }
            if (-not $candidate) { throw 'Не найдено свободное стандартное сочетание.' }
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
                if ([string]::IsNullOrWhiteSpace([string]$item.title) -or [string]::IsNullOrWhiteSpace([string]$item.text)) {
                    $list.SelectedIndex = $index
                    throw 'Заполните название и текст макроса.'
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
'@

$editorPattern = '(?s)function Show-MacroEditor \{.*?\r?\n\}\r?\n\r?\nfunction Wait-ModifierKeysReleased \{'
if (-not [regex]::IsMatch($content, $editorPattern)) {
    throw 'Show-MacroEditor block was not found.'
}
$content = [regex]::Replace($content, $editorPattern, $editorReplacement, 1)

$unregisterPattern = '(?s)(function Unregister-CurrentHotkeys \{.*?\$State\.MacroByRegistration\.Clear\(\))(\r?\n\})'
if (-not [regex]::IsMatch($content, $unregisterPattern)) {
    throw 'Unregister-CurrentHotkeys block was not found.'
}
$unregisterReplacement = '$1' + "`r`n    [System.Windows.Forms.Application]::DoEvents()`r`n    Start-Sleep -Milliseconds 120" + '$2'
$content = [regex]::Replace($content, $unregisterPattern, $unregisterReplacement, 1)

$selfTestNeedle = "    `$binding = ConvertTo-HotkeyBinding -Hotkey 'Ctrl+Alt+F24'"
$selfTestAddition = "    if ((Format-EditorHotkeySelection -Modifiers @('Alt','Ctrl') -Key '1') -cne 'Ctrl+Alt+1') { throw 'Self-test: dropdown hotkey formatting failed.' }`r`n"
if (-not $content.Contains($selfTestNeedle)) { throw 'Self-test insertion point was not found.' }
$content = $content.Replace($selfTestNeedle, $selfTestAddition + $selfTestNeedle)

[IO.File]::WriteAllText($path, $content, (New-Object Text.UTF8Encoding($true)))
Write-Output 'Hotkey dropdown patch applied.'
