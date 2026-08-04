#requires -version 5.1
param(
    [string]$MacrosPath = (Join-Path $PSScriptRoot 'macros.json'),
    [switch]$SelfTest
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$script:ErrorLog = Join-Path $PSScriptRoot 'WHAM-errors.log'
$script:StatusFile = Join-Path $PSScriptRoot 'WHAM-status.txt'

function Write-Log([string]$Message) {
    try {
        Add-Content -LiteralPath $script:ErrorLog -Encoding UTF8 -Value (
            '[{0}] {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message
        )
    } catch {}
}

function Write-Status([string]$Status, [string[]]$Details = @()) {
    try {
        $lines = @(
            "STATUS: $Status"
            "TIME: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
            "PID: $PID"
        ) + $Details
        [IO.File]::WriteAllLines(
            $script:StatusFile,
            $lines,
            (New-Object Text.UTF8Encoding($true))
        )
    } catch {}
}

function Show-AppError([string]$Message) {
    Write-Log $Message
    [System.Windows.Forms.MessageBox]::Show(
        "$Message`r`n`r`nЖурнал: $script:ErrorLog",
        'WHAM Quick Replies — ошибка',
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Error
    ) | Out-Null
}

Add-Type -ReferencedAssemblies 'System.Windows.Forms.dll','System.Drawing.dll' -TypeDefinition @'
using System;
using System.Drawing;
using System.Runtime.InteropServices;
using System.Windows.Forms;

public sealed class WhamWindow : Form
{
    private const int WM_HOTKEY = 0x0312;
    private const uint KEYUP = 0x0002;
    private const byte CTRL = 0x11;
    private const byte V = 0x56;

    [DllImport("user32.dll", SetLastError=true)]
    private static extern bool RegisterHotKey(IntPtr hWnd, int id, uint modifiers, uint key);

    [DllImport("user32.dll", SetLastError=true)]
    private static extern bool UnregisterHotKey(IntPtr hWnd, int id);

    [DllImport("user32.dll")]
    public static extern IntPtr GetForegroundWindow();

    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool SetForegroundWindow(IntPtr hWnd);

    [DllImport("user32.dll")]
    public static extern short GetAsyncKeyState(int key);

    [DllImport("user32.dll")]
    private static extern void keybd_event(byte key, byte scan, uint flags, UIntPtr extra);

    public event Action<int> HotkeyPressed;

    public WhamWindow()
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

    public void RegisterBinding(int id, uint modifiers, uint key)
    {
        IntPtr handle = Handle;
        if (!RegisterHotKey(handle, id, modifiers, key))
        {
            throw new InvalidOperationException(
                "RegisterHotKey failed. Win32 error: " + Marshal.GetLastWin32Error()
            );
        }
    }

    public void UnregisterBinding(int id)
    {
        if (IsHandleCreated)
        {
            UnregisterHotKey(Handle, id);
        }
    }

    public static void Paste()
    {
        keybd_event(CTRL, 0, 0, UIntPtr.Zero);
        keybd_event(V, 0, 0, UIntPtr.Zero);
        keybd_event(V, 0, KEYUP, UIntPtr.Zero);
        keybd_event(CTRL, 0, KEYUP, UIntPtr.Zero);
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

function Get-Defaults {
    @(
        [pscustomobject]@{ id='macro-1'; title='Проверка WHAM'; hotkey='Ctrl+Alt+1'; text='Добрый день! Макрос WHAM работает.' }
        [pscustomobject]@{ id='macro-2'; title='Заявка принята'; hotkey='Ctrl+Alt+2'; text='Добрый день! Заявка принята в работу.' }
        [pscustomobject]@{ id='macro-3'; title='Не хватает данных'; hotkey='Ctrl+Alt+3'; text='Добрый день! Для продолжения работы не хватает данных.' }
        [pscustomobject]@{ id='macro-4'; title='Уточните договор'; hotkey='Ctrl+Alt+4'; text='Добрый день! Пожалуйста, уточните номер договора.' }
        [pscustomobject]@{ id='macro-5'; title='Принял в обработку'; hotkey='Ctrl+Alt+5'; text='Добрый день! Принял информацию в обработку.' }
    )
}

function Get-PropertyText($Object, [string[]]$Names) {
    foreach ($name in $Names) {
        $property = $Object.PSObject.Properties[$name]
        if ($null -ne $property) { return [string]$property.Value }
    }
    return $null
}

function Get-Binding([string]$Hotkey) {
    if ([string]::IsNullOrWhiteSpace($Hotkey)) {
        throw 'Не указана горячая клавиша.'
    }

    $parts = @(($Hotkey -replace '\s','') -split '\+')
    [uint32]$modifiers = 0x4000
    $mainKey = $null
    $hasCtrl = $false
    $hasAlt = $false
    $hasShift = $false
    $hasWin = $false

    foreach ($part in $parts) {
        switch ($part.ToUpperInvariant()) {
            'CTRL' { $hasCtrl = $true; $modifiers = $modifiers -bor 0x0002 }
            'CONTROL' { $hasCtrl = $true; $modifiers = $modifiers -bor 0x0002 }
            'ALT' { $hasAlt = $true; $modifiers = $modifiers -bor 0x0001 }
            'SHIFT' { $hasShift = $true; $modifiers = $modifiers -bor 0x0004 }
            'WIN' { $hasWin = $true; $modifiers = $modifiers -bor 0x0008 }
            default {
                if ($null -ne $mainKey) {
                    throw "В комбинации '$Hotkey' больше одной основной клавиши."
                }
                $mainKey = $part
            }
        }
    }

    if ($null -eq $mainKey -or [string]::IsNullOrWhiteSpace($mainKey)) {
        throw "В комбинации '$Hotkey' нет основной клавиши."
    }
    if (($modifiers -band 0x000F) -eq 0) {
        throw "Комбинация '$Hotkey' должна содержать Ctrl, Alt, Shift или Win."
    }

    $enumName = $mainKey
    if ($enumName -match '^[0-9]$') { $enumName = "D$enumName" }

    try {
        $keyCode = [Enum]::Parse([System.Windows.Forms.Keys], $enumName, $true)
    } catch {
        throw "Клавиша '$mainKey' не поддерживается."
    }

    if ($mainKey -match '^[a-z]$' -or $mainKey -match '^f([1-9]|1[0-9]|2[0-4])$') {
        $mainKey = $mainKey.ToUpperInvariant()
    }

    $canonical = New-Object System.Collections.Generic.List[string]
    if ($hasCtrl) { $canonical.Add('Ctrl') }
    if ($hasAlt) { $canonical.Add('Alt') }
    if ($hasShift) { $canonical.Add('Shift') }
    if ($hasWin) { $canonical.Add('Win') }
    $canonical.Add($mainKey)

    [pscustomobject]@{
        Hotkey = ($canonical -join '+')
        Modifiers = [uint32]$modifiers
        Key = [uint32][int]$keyCode
    }
}

function Save-Macros([string]$Path, [object[]]$Macros) {
    $json = ConvertTo-Json -InputObject @($Macros) -Depth 4
    [IO.File]::WriteAllText(
        $Path,
        $json,
        (New-Object Text.UTF8Encoding($true))
    )
}

function Backup-File([string]$Path, [string]$Reason) {
    if (Test-Path -LiteralPath $Path -PathType Leaf) {
        $backupPath = "$Path.$Reason.$(Get-Date -Format 'yyyyMMdd-HHmmss-fff').bak"
        Copy-Item -LiteralPath $Path -Destination $backupPath -Force
        return $backupPath
    }
    return $null
}

function ConvertTo-ItemArray($Decoded) {
    if ($null -eq $Decoded) { return @() }
    if ($Decoded -is [System.Array]) {
        return @($Decoded | ForEach-Object { $_ })
    }
    return @($Decoded)
}

function Read-Macros([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        $defaults = @(Get-Defaults)
        Save-Macros $Path $defaults
        return $defaults
    }

    try {
        $raw = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
        $items = @(ConvertTo-ItemArray (ConvertFrom-Json -InputObject $raw))
    } catch {
        Backup-File $Path 'broken' | Out-Null
        $defaults = @(Get-Defaults)
        Save-Macros $Path $defaults
        Write-Log 'Повреждённый macros.json сохранён как резервная копия.'
        return $defaults
    }

    if ($items.Count -eq 0) {
        Backup-File $Path 'empty' | Out-Null
        $defaults = @(Get-Defaults)
        Save-Macros $Path $defaults
        return $defaults
    }

    $normalized = New-Object System.Collections.ArrayList
    $changed = $false

    for ($index = 0; $index -lt $items.Count; $index++) {
        $item = $items[$index]
        $id = Get-PropertyText $item @('id')
        $title = Get-PropertyText $item @('title','name')
        $hotkey = Get-PropertyText $item @('hotkey','shortcut','key')
        $text = Get-PropertyText $item @('text','content','template')

        if ([string]::IsNullOrWhiteSpace($id)) {
            $id = "macro-$([Guid]::NewGuid().ToString('N'))"
            $changed = $true
        }
        if ([string]::IsNullOrWhiteSpace($title)) {
            $title = "Макрос $($index + 1)"
            $changed = $true
        }
        if ([string]::IsNullOrWhiteSpace($hotkey)) {
            $hotkey = "Ctrl+Alt+$([Math]::Min($index + 1,9))"
            $changed = $true
        }
        if ($null -eq $text) {
            $text = ''
            $changed = $true
        }
        if ([string]::IsNullOrWhiteSpace([string]$text)) {
            throw "Текст макроса '$title' пуст."
        }

        $binding = Get-Binding $hotkey
        if ($binding.Hotkey -cne $hotkey) { $changed = $true }

        [void]$normalized.Add([pscustomobject]@{
            id = $id.Trim()
            title = $title.Trim()
            hotkey = $binding.Hotkey
            text = [string]$text
        })
    }

    $ids = @{}
    $hotkeys = @{}
    foreach ($macro in $normalized) {
        if ($ids.ContainsKey([string]$macro.id)) {
            $macro.id = "macro-$([Guid]::NewGuid().ToString('N'))"
            $changed = $true
        }
        $hotkeyKey = ([string]$macro.hotkey).ToUpperInvariant()
        if ($hotkeys.ContainsKey($hotkeyKey)) {
            throw "Комбинация '$($macro.hotkey)' назначена нескольким макросам."
        }
        $ids[[string]$macro.id] = $true
        $hotkeys[$hotkeyKey] = $true
    }

    if ($changed) {
        Backup-File $Path 'before-migration' | Out-Null
        Save-Macros $Path @($normalized)
    }

    return @($normalized | ForEach-Object { $_ })
}

function Wait-ModifiersReleased {
    $deadline = [DateTime]::UtcNow.AddSeconds(3)
    while ([DateTime]::UtcNow -lt $deadline) {
        $pressed = $false
        foreach ($code in @(0x10,0x11,0x12,0x5B,0x5C)) {
            if (([WhamWindow]::GetAsyncKeyState($code) -band 0x8000) -ne 0) {
                $pressed = $true
                break
            }
        }
        if (-not $pressed) { return }
        Start-Sleep -Milliseconds 20
    }
}

function Set-ClipboardText([string]$Text) {
    $lastError = $null
    foreach ($attempt in 1..20) {
        try {
            [System.Windows.Forms.Clipboard]::SetText(
                $Text,
                [System.Windows.Forms.TextDataFormat]::UnicodeText
            )
            return
        } catch {
            $lastError = $_
            Start-Sleep -Milliseconds 50
        }
    }
    throw "Буфер обмена недоступен: $($lastError.Exception.Message)"
}

function Paste-Text([string]$Text, [IntPtr]$TargetWindow) {
    Set-ClipboardText $Text
    Wait-ModifiersReleased
    if ($TargetWindow -ne [IntPtr]::Zero) {
        [void][WhamWindow]::SetForegroundWindow($TargetWindow)
        Start-Sleep -Milliseconds 120
    }
    [WhamWindow]::Paste()
}

function Unregister-All([WhamWindow]$HotkeyWindow, $State) {
    foreach ($registrationId in @($State.RegisteredIds)) {
        $HotkeyWindow.UnregisterBinding([int]$registrationId)
    }
    $State.RegisteredIds.Clear()
    $State.MacroByRegistration.Clear()
}

function Register-Set([WhamWindow]$HotkeyWindow, $State, [object[]]$Macros) {
    for ($index = 0; $index -lt $Macros.Count; $index++) {
        $macro = $Macros[$index]
        $binding = Get-Binding ([string]$macro.hotkey)
        $registrationId = 1001 + $index
        try {
            $HotkeyWindow.RegisterBinding(
                $registrationId,
                [uint32]$binding.Modifiers,
                [uint32]$binding.Key
            )
        } catch {
            throw (
                "Не удалось назначить '$($binding.Hotkey)' макросу " +
                "'$($macro.title)'. Комбинация занята другой программой."
            )
        }
        [void]$State.RegisteredIds.Add($registrationId)
        $State.MacroByRegistration[$registrationId] = [string]$macro.id
    }
}

function Register-All([WhamWindow]$HotkeyWindow, $State, [object[]]$Macros) {
    $oldMacros = @($State.Macros)
    Unregister-All $HotkeyWindow $State
    Start-Sleep -Milliseconds 80
    try {
        Register-Set $HotkeyWindow $State $Macros
        $State.Macros = @($Macros)
    } catch {
        $message = $_.Exception.Message
        Unregister-All $HotkeyWindow $State
        if ($oldMacros.Count -gt 0) {
            try {
                Register-Set $HotkeyWindow $State $oldMacros
                $State.Macros = @($oldMacros)
            } catch {
                Write-Log "Не удалось восстановить предыдущие горячие клавиши: $($_.Exception.Message)"
            }
        }
        throw $message
    }

    Write-Status 'RUNNING' @(
        "MACROS: $($State.Macros.Count)"
        "HOTKEYS: $((@($State.Macros | ForEach-Object { $_.hotkey })) -join ', ')"
    )
}

function Show-MacroEditor([object[]]$Macros) {
    $result = [pscustomobject]@{ Saved = $false; Macros = @() }

    $form = New-Object System.Windows.Forms.Form
    $form.Text = 'WHAM Quick Replies — управление макросами'
    $form.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterScreen
    $form.Size = New-Object System.Drawing.Size(980, 620)
    $form.MinimumSize = New-Object System.Drawing.Size(760, 480)
    $form.ShowInTaskbar = $true

    $hint = New-Object System.Windows.Forms.Label
    $hint.Dock = [System.Windows.Forms.DockStyle]::Top
    $hint.Height = 42
    $hint.Padding = New-Object System.Windows.Forms.Padding(8, 8, 8, 4)
    $hint.Text = 'Меняйте название, горячую клавишу и текст. Для нового макроса заполните последнюю пустую строку.'
    $form.Controls.Add($hint)

    $buttons = New-Object System.Windows.Forms.FlowLayoutPanel
    $buttons.Dock = [System.Windows.Forms.DockStyle]::Bottom
    $buttons.Height = 48
    $buttons.FlowDirection = [System.Windows.Forms.FlowDirection]::RightToLeft
    $buttons.Padding = New-Object System.Windows.Forms.Padding(6)
    $form.Controls.Add($buttons)

    $saveButton = New-Object System.Windows.Forms.Button
    $saveButton.Text = 'Сохранить'
    $saveButton.Width = 110
    $saveButton.Height = 30
    $buttons.Controls.Add($saveButton)

    $cancelButton = New-Object System.Windows.Forms.Button
    $cancelButton.Text = 'Отмена'
    $cancelButton.Width = 110
    $cancelButton.Height = 30
    $cancelButton.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    $buttons.Controls.Add($cancelButton)

    $deleteButton = New-Object System.Windows.Forms.Button
    $deleteButton.Text = 'Удалить выбранные'
    $deleteButton.Width = 150
    $deleteButton.Height = 30
    $buttons.Controls.Add($deleteButton)

    $grid = New-Object System.Windows.Forms.DataGridView
    $grid.Dock = [System.Windows.Forms.DockStyle]::Fill
    $grid.AutoGenerateColumns = $false
    $grid.AllowUserToAddRows = $true
    $grid.AllowUserToDeleteRows = $true
    $grid.MultiSelect = $true
    $grid.SelectionMode = [System.Windows.Forms.DataGridViewSelectionMode]::FullRowSelect
    $grid.RowHeadersVisible = $false
    $grid.RowTemplate.Height = 70
    $grid.AutoSizeRowsMode = [System.Windows.Forms.DataGridViewAutoSizeRowsMode]::None
    $grid.DefaultCellStyle.WrapMode = [System.Windows.Forms.DataGridViewTriState]::True
    $form.Controls.Add($grid)
    $grid.BringToFront()

    $titleColumn = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
    $titleColumn.HeaderText = 'Название'
    $titleColumn.Name = 'Title'
    $titleColumn.Width = 190
    [void]$grid.Columns.Add($titleColumn)

    $hotkeyColumn = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
    $hotkeyColumn.HeaderText = 'Горячая клавиша'
    $hotkeyColumn.Name = 'Hotkey'
    $hotkeyColumn.Width = 150
    [void]$grid.Columns.Add($hotkeyColumn)

    $textColumn = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
    $textColumn.HeaderText = 'Текст макроса'
    $textColumn.Name = 'Text'
    $textColumn.AutoSizeMode = [System.Windows.Forms.DataGridViewAutoSizeColumnMode]::Fill
    [void]$grid.Columns.Add($textColumn)

    foreach ($macro in $Macros) {
        $rowIndex = $grid.Rows.Add()
        $row = $grid.Rows[$rowIndex]
        $row.Tag = [string]$macro.id
        $row.Cells['Title'].Value = [string]$macro.title
        $row.Cells['Hotkey'].Value = [string]$macro.hotkey
        $row.Cells['Text'].Value = [string]$macro.text
    }

    $grid.add_EditingControlShowing({
        param($sender, $eventArgs)
        if ($eventArgs.Control -is [System.Windows.Forms.DataGridViewTextBoxEditingControl]) {
            $eventArgs.Control.Multiline = $true
            $eventArgs.Control.AcceptsReturn = $true
        }
    })

    $deleteButton.add_Click({
        $rows = @($grid.SelectedRows | Where-Object { -not $_.IsNewRow } | Sort-Object Index -Descending)
        foreach ($row in $rows) { $grid.Rows.RemoveAt($row.Index) }
    })

    $saveButton.add_Click({
        try {
            $grid.EndEdit()
            $items = New-Object System.Collections.ArrayList
            $hotkeys = @{}

            foreach ($row in $grid.Rows) {
                if ($row.IsNewRow) { continue }

                $title = [string]$row.Cells['Title'].Value
                $hotkey = [string]$row.Cells['Hotkey'].Value
                $text = [string]$row.Cells['Text'].Value

                if ([string]::IsNullOrWhiteSpace($title) -and
                    [string]::IsNullOrWhiteSpace($hotkey) -and
                    [string]::IsNullOrWhiteSpace($text)) {
                    continue
                }
                if ([string]::IsNullOrWhiteSpace($title)) {
                    throw 'У каждого макроса должно быть название.'
                }
                if ([string]::IsNullOrWhiteSpace($text)) {
                    throw "Текст макроса '$title' пуст."
                }

                $binding = Get-Binding $hotkey
                $key = $binding.Hotkey.ToUpperInvariant()
                if ($hotkeys.ContainsKey($key)) {
                    throw "Комбинация '$($binding.Hotkey)' назначена нескольким макросам."
                }
                $hotkeys[$key] = $true

                $id = [string]$row.Tag
                if ([string]::IsNullOrWhiteSpace($id)) {
                    $id = "macro-$([Guid]::NewGuid().ToString('N'))"
                }

                [void]$items.Add([pscustomobject]@{
                    id = $id
                    title = $title.Trim()
                    hotkey = $binding.Hotkey
                    text = $text
                })
            }

            if ($items.Count -eq 0) {
                throw 'Должен остаться хотя бы один макрос.'
            }

            $result.Macros = @($items | ForEach-Object { $_ })
            $result.Saved = $true
            $form.Close()
        } catch {
            [System.Windows.Forms.MessageBox]::Show(
                $_.Exception.Message,
                'Не удалось сохранить макросы',
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Warning
            ) | Out-Null
        }
    })

    $form.AcceptButton = $saveButton
    $form.CancelButton = $cancelButton
    [void]$form.ShowDialog()
    $form.Dispose()
    return $result
}

function Run-SelfTest {
    $temporaryDirectory = Join-Path ([IO.Path]::GetTempPath()) "wham-$([Guid]::NewGuid().ToString('N'))"
    $temporaryPath = Join-Path $temporaryDirectory 'macros.json'
    try {
        New-Item -ItemType Directory -Path $temporaryDirectory -Force | Out-Null
        $macros = @(Get-Defaults)
        $macros[0].text = "Русский English 中文`r`nВторая строка"
        Save-Macros $temporaryPath $macros

        $loaded = @(Read-Macros $temporaryPath)
        if ($loaded.Count -ne 5) {
            throw "Тест чтения macros.json не пройден: ожидалось 5, получено $($loaded.Count)."
        }
        if ([string]$loaded[0].text -cne [string]$macros[0].text) {
            throw 'Тест Unicode не пройден.'
        }
        foreach ($macro in $loaded) {
            [void](Get-Binding ([string]$macro.hotkey))
        }

        $legacy = @([pscustomobject]@{
            title = 'Старый макрос'
            hotkey = 'Ctrl+Shift+9'
            text = 'Сохранить этот текст'
        })
        [IO.File]::WriteAllText(
            $temporaryPath,
            (ConvertTo-Json -InputObject $legacy -Depth 4),
            (New-Object Text.UTF8Encoding($true))
        )
        $migrated = @(Read-Macros $temporaryPath)
        if ($migrated.Count -ne 1 -or [string]$migrated[0].text -cne 'Сохранить этот текст') {
            throw 'Тест миграции старого macros.json не пройден.'
        }
        if ([string]::IsNullOrWhiteSpace([string]$migrated[0].id)) {
            throw 'Тест восстановления id не пройден.'
        }

        'WHAM self-test passed.'
    } finally {
        Remove-Item -LiteralPath $temporaryDirectory -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Run-App {
    $mutex = New-Object System.Threading.Mutex($false, 'Local\WHAM.QuickReplies.TextMacros')
    $ownsMutex = $false

    try {
        try {
            $ownsMutex = $mutex.WaitOne(0,$false)
        } catch [System.Threading.AbandonedMutexException] {
            $ownsMutex = $true
        }

        if (-not $ownsMutex) {
            [System.Windows.Forms.MessageBox]::Show(
                'WHAM уже запущен. Значок находится рядом с часами.',
                'WHAM Quick Replies',
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Information
            ) | Out-Null
            return
        }

        $hotkeyWindow = New-Object WhamWindow
        $trayIcon = New-Object System.Windows.Forms.NotifyIcon
        $menu = New-Object System.Windows.Forms.ContextMenuStrip
        $state = [pscustomobject]@{
            Macros = @()
            RegisteredIds = New-Object System.Collections.ArrayList
            MacroByRegistration = @{}
            Busy = $false
        }

        try {
            Register-All $hotkeyWindow $state @(Read-Macros $MacrosPath)

            $hotkeyWindow.add_HotkeyPressed({
                param([int]$registrationId)
                if ($state.Busy) { return }
                $state.Busy = $true
                $targetWindow = [WhamWindow]::GetForegroundWindow()
                try {
                    $macroId = [string]$state.MacroByRegistration[$registrationId]
                    $macro = $state.Macros |
                        Where-Object { [string]$_.id -ceq $macroId } |
                        Select-Object -First 1
                    if ($null -eq $macro) { throw 'Макрос не найден.' }
                    Paste-Text ([string]$macro.text) $targetWindow
                } catch {
                    Show-AppError "Не удалось вставить текст.`r`n$($_.Exception.Message)"
                } finally {
                    $state.Busy = $false
                }
            })

            $manageItem = $menu.Items.Add("Управление макросами ($($state.Macros.Count))")
            $manageItem.ToolTipText = 'Изменить тексты, названия и горячие клавиши'
            $manageItem.add_Click({
                if ($state.Busy) { return }
                $state.Busy = $true
                try {
                    $editorResult = Show-MacroEditor -Macros @($state.Macros)
                    if (-not $editorResult.Saved) { return }

                    $oldMacros = @($state.Macros | ForEach-Object {
                        [pscustomobject]@{
                            id = [string]$_.id
                            title = [string]$_.title
                            hotkey = [string]$_.hotkey
                            text = [string]$_.text
                        }
                    })
                    $newMacros = @($editorResult.Macros)

                    Backup-File $MacrosPath 'before-editor-save' | Out-Null
                    Save-Macros $MacrosPath $newMacros
                    try {
                        Register-All $hotkeyWindow $state $newMacros
                    } catch {
                        Save-Macros $MacrosPath $oldMacros
                        throw
                    }

                    $manageItem.Text = "Управление макросами ($($state.Macros.Count))"
                    $trayIcon.ShowBalloonTip(
                        1600,
                        'WHAM Quick Replies',
                        'Макросы сохранены и горячие клавиши обновлены.',
                        [System.Windows.Forms.ToolTipIcon]::Info
                    )
                } catch {
                    Show-AppError $_.Exception.Message
                } finally {
                    $state.Busy = $false
                }
            })

            $openItem = $menu.Items.Add('Открыть macros.json в Блокноте')
            $openItem.add_Click({
                Start-Process notepad.exe -ArgumentList ('"{0}"' -f $MacrosPath)
            })

            $reloadItem = $menu.Items.Add('Перезагрузить макросы')
            $reloadItem.add_Click({
                try {
                    Register-All $hotkeyWindow $state @(Read-Macros $MacrosPath)
                    $manageItem.Text = "Управление макросами ($($state.Macros.Count))"
                    $trayIcon.ShowBalloonTip(
                        1500,
                        'WHAM Quick Replies',
                        'Макросы перезагружены.',
                        [System.Windows.Forms.ToolTipIcon]::Info
                    )
                } catch {
                    Show-AppError $_.Exception.Message
                }
            })

            [void]$menu.Items.Add('-')
            $exitItem = $menu.Items.Add('Выход')
            $exitItem.add_Click({ $hotkeyWindow.Close() })

            $trayIcon.Icon = [System.Drawing.SystemIcons]::Information
            $trayIcon.Text = 'WHAM Quick Replies'
            $trayIcon.ContextMenuStrip = $menu
            $trayIcon.Visible = $true
            $trayIcon.ShowBalloonTip(
                1800,
                'WHAM Quick Replies',
                "$($state.Macros.Count) текстовых макросов активно.",
                [System.Windows.Forms.ToolTipIcon]::Info
            )

            [System.Windows.Forms.Application]::Run($hotkeyWindow)
        } finally {
            Write-Status 'STOPPED'
            $trayIcon.Visible = $false
            $trayIcon.Dispose()
            $menu.Dispose()
            Unregister-All $hotkeyWindow $state
            $hotkeyWindow.Dispose()
        }
    } finally {
        if ($ownsMutex) {
            try { $mutex.ReleaseMutex() } catch {}
        }
        $mutex.Dispose()
    }
}

try {
    if ($SelfTest) {
        Run-SelfTest
        exit 0
    }
    Run-App
} catch {
    $message = $_.Exception.Message
    Write-Status 'ERROR' @("ERROR: $message")
    Write-Log ($_.Exception.ToString())
    if ($SelfTest) {
        Write-Error $message
        exit 1
    }
    Show-AppError $message
    exit 1
}
