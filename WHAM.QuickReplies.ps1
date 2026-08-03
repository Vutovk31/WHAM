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

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Macros file not found: $Path"
    }

    try {
        $parsed = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
    }
    catch {
        throw "Не удалось прочитать macros.json. Проверьте кавычки, запятые и фигурные скобки. $($_.Exception.Message)"
    }

    $items = @(foreach ($item in $parsed) { $item })
    if ($items.Count -eq 0) { throw 'At least one macro is required.' }

    $seenIds = @{}
    $seenHotkeys = @{}
    foreach ($item in $items) {
        foreach ($property in 'id', 'title', 'hotkey', 'text') {
            if (-not $item.PSObject.Properties[$property] -or [string]::IsNullOrWhiteSpace([string]$item.$property)) {
                throw "Macro is missing required property '$property'."
            }
        }

        $id = ([string]$item.id).Trim()
        if ($seenIds.ContainsKey($id)) { throw "Duplicate macro id: $id" }
        $seenIds[$id] = $true

        $normalizedHotkey = ([string]$item.hotkey).Trim().ToUpperInvariant()
        if ($seenHotkeys.ContainsKey($normalizedHotkey)) { throw "Duplicate hotkey: $($item.hotkey)" }
        $seenHotkeys[$normalizedHotkey] = $true
    }

    return $items
}

function Write-Macros {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][Collections.IEnumerable]$Macros
    )

    $items = @(foreach ($macro in $Macros) { $macro })
    if ($items.Count -eq 0) { throw 'At least one macro is required.' }

    $directory = Split-Path -Parent $Path
    if ($directory -and -not (Test-Path -LiteralPath $directory -PathType Container)) {
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
    }

    $json = ConvertTo-Json -InputObject $items -Depth 4
    $tempPath = "$Path.tmp"
    [IO.File]::WriteAllText($tempPath, $json, [Text.UTF8Encoding]::new($true))
    Move-Item -LiteralPath $tempPath -Destination $Path -Force
}

function ConvertTo-HotkeyBinding {
    param([Parameter(Mandatory)][string]$Hotkey)

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
                if ($keyName) { throw "Hotkey must contain exactly one key: $Hotkey" }
                $keyName = $token
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
    foreach ($item in $items) { [void]$list.Items.Add($item.title) }
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
    $textLabel.Text = 'Текст макроса. Поля в {скобках} запрашиваются перед вставкой.'
    $textLabel.Location = [Drawing.Point]::new(252, 146)
    $textLabel.Size = [Drawing.Size]::new(520, 24)
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

    $loading = $false
    $currentIndex = -1

    $updateCurrent = {
        if ($loading -or $currentIndex -lt 0 -or $currentIndex -ge $items.Count) { return }
        $items[$currentIndex].title = $titleInput.Text
        $items[$currentIndex].hotkey = $hotkeyInput.Text
        $items[$currentIndex].text = $textInput.Text
        $list.Items[$currentIndex] = $(if ([string]::IsNullOrWhiteSpace($titleInput.Text)) { '(без названия)' } else { $titleInput.Text })
    }

    $list.add_SelectedIndexChanged({
        if ($loading) { return }
        $currentIndex = $list.SelectedIndex
        $loading = $true
        try {
            $enabled = $currentIndex -ge 0
            $titleInput.Enabled = $enabled
            $hotkeyInput.Enabled = $enabled
            $textInput.Enabled = $enabled
            $deleteButton.Enabled = $enabled
            if ($enabled) {
                $titleInput.Text = [string]$items[$currentIndex].title
                $hotkeyInput.Text = [string]$items[$currentIndex].hotkey
                $textInput.Text = [string]$items[$currentIndex].text
            }
            else {
                $titleInput.Clear()
                $hotkeyInput.Clear()
                $textInput.Clear()
            }
        }
        finally {
            $loading = $false
        }
    })

    $titleInput.add_TextChanged({ & $updateCurrent })
    $hotkeyInput.add_TextChanged({ & $updateCurrent })
    $textInput.add_TextChanged({ & $updateCurrent })

    $addButton.add_Click({
        $used = @{}
        foreach ($item in $items) { $used[([string]$item.hotkey).ToUpperInvariant()] = $true }

        $candidate = ''
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

        $item = [pscustomobject]@{
            id = "macro-$([Guid]::NewGuid().ToString('N'))"
            title = 'Новый макрос'
            hotkey = $candidate
            text = 'Новый текст'
        }
        [void]$items.Add($item)
        [void]$list.Items.Add($item.title)
        $list.SelectedIndex = $items.Count - 1
        $titleInput.SelectAll()
        $titleInput.Focus() | Out-Null
    })

    $deleteButton.add_Click({
        if ($currentIndex -lt 0) { return }
        if ($items.Count -eq 1) {
            [System.Windows.Forms.MessageBox]::Show('Должен остаться хотя бы один макрос.', 'WHAM Quick Replies', 'OK', 'Warning') | Out-Null
            return
        }

        $answer = [System.Windows.Forms.MessageBox]::Show(
            "Удалить макрос '$($items[$currentIndex].title)'?",
            'WHAM Quick Replies',
            'YesNo',
            'Question'
        )
        if ($answer -ne [System.Windows.Forms.DialogResult]::Yes) { return }

        $removeIndex = $currentIndex
        $items.RemoveAt($removeIndex)
        $list.Items.RemoveAt($removeIndex)
        $list.SelectedIndex = [Math]::Min($removeIndex, $items.Count - 1)
    })

    $saveButton.add_Click({
        & $updateCurrent
        $seen = @{}

        for ($index = 0; $index -lt $items.Count; $index++) {
            $item = $items[$index]
            if ([string]::IsNullOrWhiteSpace([string]$item.title) -or
                [string]::IsNullOrWhiteSpace([string]$item.hotkey) -or
                [string]::IsNullOrWhiteSpace([string]$item.text)) {
                $list.SelectedIndex = $index
                [System.Windows.Forms.MessageBox]::Show(
                    'Заполните название, горячую клавишу и текст.',
                    'WHAM Quick Replies',
                    'OK',
                    'Warning'
                ) | Out-Null
                return
            }

            $item.title = ([string]$item.title).Trim()
            $item.hotkey = ([string]$item.hotkey).Trim()
            [void](ConvertTo-HotkeyBinding -Hotkey $item.hotkey)

            $normalized = $item.hotkey.ToUpperInvariant()
            if ($seen.ContainsKey($normalized)) {
                $list.SelectedIndex = $index
                [System.Windows.Forms.MessageBox]::Show(
                    "Горячая клавиша '$($item.hotkey)' назначена нескольким макросам.",
                    'WHAM Quick Replies',
                    'OK',
                    'Warning'
                ) | Out-Null
                return
            }
            $seen[$normalized] = $true
        }

        try {
            Write-Macros -Path $Path -Macros $items
            [System.Windows.Forms.MessageBox]::Show(
                'Макросы сохранены. WHAM перезапустится и сразу применит новый текст и сочетания.',
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
        return $form.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK
    }
    finally {
        $form.Dispose()
    }
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

    foreach ($input in $inputs.Values) { $input.add_TextChanged({ & $refreshPreview }) }
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
    finally {
        $form.Dispose()
    }
}

function Set-ClipboardTextWithRetry {
    param([Parameter(Mandatory)][string]$Text)

    $lastError = $null
    foreach ($attempt in 1..8) {
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
        # Clipboard ownership can change at any time. A failed restore must never crash WHAM.
    }
}

function Invoke-SafePaste {
    param([Parameter(Mandatory)][string]$Text)

    $snapshot = $null
    try {
        $snapshot = [System.Windows.Forms.Clipboard]::GetDataObject()
    }
    catch {
        $snapshot = $null
    }

    Set-ClipboardTextWithRetry -Text $Text
    Start-Sleep -Milliseconds 250

    try {
        [System.Windows.Forms.SendKeys]::SendWait('^v')
    }
    catch {
        Restore-ClipboardSnapshot -Snapshot $snapshot -ExpectedText $Text
        throw
    }

    Start-Sleep -Milliseconds 700
    Restore-ClipboardSnapshot -Snapshot $snapshot -ExpectedText $Text
}

function Find-MacroById {
    param(
        [Parameter(Mandatory)][object[]]$Macros,
        [Parameter(Mandatory)][string]$Id
    )

    foreach ($macro in $Macros) {
        if ([string]$macro.id -ceq $Id) { return $macro }
    }
    return $null
}

if ($SelfTest) {
    $testMacros = @(Read-Macros -Path $MacrosPath)
    if ($testMacros.Count -ne 5) { throw "Self-test expected 5 macros, got $($testMacros.Count)." }

    $variables = @(Get-TemplateVariables -Template 'Добрый день, {имя}! Заказ №{номер}.')
    if (($variables -join ',') -ne 'имя,номер') { throw 'Variable extraction self-test failed.' }

    $noVariables = @(Get-TemplateVariables -Template 'Текст без переменных')
    if ($noVariables.Count -ne 0) { throw 'Plain-text macro self-test failed.' }

    $rendered = Expand-Template -Template 'Добрый день, {имя}!' -Values @{ 'имя' = 'Тест' }
    if ($rendered -ne 'Добрый день, Тест!') { throw 'Template expansion self-test failed.' }

    $altBinding = ConvertTo-HotkeyBinding -Hotkey 'Alt+1'
    if (($altBinding.Modifiers -band 0x0001) -eq 0) { throw 'Alt+1 parsing self-test failed.' }

    $roundTripPath = Join-Path ([IO.Path]::GetTempPath()) "wham-$([Guid]::NewGuid().ToString('N')).json"
    try {
        Write-Macros -Path $roundTripPath -Macros $testMacros
        $roundTrip = @(Read-Macros -Path $roundTripPath)
        if ($roundTrip.Count -ne 5 -or $roundTrip[0].text -cne $testMacros[0].text) {
            throw 'Macro editor storage self-test failed.'
        }
    }
    finally {
        Remove-Item -LiteralPath $roundTripPath -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath "$roundTripPath.tmp" -Force -ErrorAction SilentlyContinue
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
            throw "Не удалось назначить '$($macros[$index].hotkey)' макросу '$($macros[$index].title)'. Сочетание занято другой программой или Windows. Измените hotkey и перезапустите WHAM. $($_.Exception.Message)"
        }

        $registeredIds.Add($registrationId)
        $macroIdsByRegistration[$registrationId] = [string]$macros[$index].id
    }

    $hotkeyWindow.add_HotkeyPressed({
        param([int]$registrationId)

        try {
            $latestMacros = @(Read-Macros -Path $MacrosPath)
            $macroId = [string]$macroIdsByRegistration[$registrationId]
            $macro = Find-MacroById -Macros $latestMacros -Id $macroId
            if ($null -eq $macro) {
                throw "Макрос '$macroId' больше не найден. Перезапустите WHAM."
            }

            $rendered = Show-TemplateDialog -Title ([string]$macro.title) -Template ([string]$macro.text)
            if ($null -eq $rendered) { return }
            Invoke-SafePaste -Text $rendered
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
    $exitItem.add_Click({ [System.Windows.Forms.Application]::Exit() })

    $notifyIcon.Icon = [System.Drawing.SystemIcons]::Information
    $notifyIcon.Text = 'WHAM Quick Replies'
    $notifyIcon.ContextMenuStrip = $menu
    $notifyIcon.Visible = $true
    $notifyIcon.ShowBalloonTip(2500, 'WHAM Quick Replies', "$($macros.Count) макросов активны.", 'Info')

    [System.Windows.Forms.Application]::Run()
}
finally {
    $notifyIcon.Visible = $false
    $notifyIcon.Dispose()
    $menu.Dispose()
    foreach ($id in $registeredIds) { $hotkeyWindow.Unregister($id) }
    $hotkeyWindow.Dispose()
}

if ($script:restartRequested) {
    $restartArguments = "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -STA -File `"$PSCommandPath`" -MacrosPath `"$MacrosPath`""
    Start-Process -FilePath 'powershell.exe' -ArgumentList $restartArguments
}
