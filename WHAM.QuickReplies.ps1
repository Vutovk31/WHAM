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
        if ($null -ne $property) {
            return [string]$property.Value
        }
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
    $canonical = New-Object System.Collections.Generic.List[string]

    foreach ($part in $parts) {
        switch ($part.ToUpperInvariant()) {
            'CTRL' {
                $modifiers = $modifiers -bor 0x0002
                if (-not $canonical.Contains('Ctrl')) { $canonical.Add('Ctrl') }
            }
            'CONTROL' {
                $modifiers = $modifiers -bor 0x0002
                if (-not $canonical.Contains('Ctrl')) { $canonical.Add('Ctrl') }
            }
            'ALT' {
                $modifiers = $modifiers -bor 0x0001
                if (-not $canonical.Contains('Alt')) { $canonical.Add('Alt') }
            }
            'SHIFT' {
                $modifiers = $modifiers -bor 0x0004
                if (-not $canonical.Contains('Shift')) { $canonical.Add('Shift') }
            }
            'WIN' {
                $modifiers = $modifiers -bor 0x0008
                if (-not $canonical.Contains('Win')) { $canonical.Add('Win') }
            }
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
    if ($enumName -match '^[0-9]$') {
        $enumName = "D$enumName"
    }

    try {
        $keyCode = [Enum]::Parse([System.Windows.Forms.Keys], $enumName, $true)
    } catch {
        throw "Клавиша '$mainKey' не поддерживается."
    }

    if ($mainKey -match '^[a-z]$' -or $mainKey -match '^f([1-9]|1[0-2])$') {
        $mainKey = $mainKey.ToUpperInvariant()
    }
    $canonical.Add($mainKey)

    [pscustomobject]@{
        Hotkey = ($canonical -join '+')
        Modifiers = [uint32]$modifiers
        Key = [uint32][int]$keyCode
    }
}

function Save-Macros([string]$Path, [object[]]$Macros) {
    $json = ConvertTo-Json @($Macros) -Depth 4
    [IO.File]::WriteAllText(
        $Path,
        $json,
        (New-Object Text.UTF8Encoding($true))
    )
}

function Backup-File([string]$Path, [string]$Reason) {
    if (Test-Path -LiteralPath $Path -PathType Leaf) {
        Copy-Item -LiteralPath $Path -Destination (
            "$Path.$Reason.$(Get-Date -Format 'yyyyMMdd-HHmmss').bak"
        ) -Force
    }
}

function Read-Macros([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        $defaults = @(Get-Defaults)
        Save-Macros $Path $defaults
        return $defaults
    }

    try {
        $items = @(
            Get-Content -LiteralPath $Path -Raw -Encoding UTF8 |
            ConvertFrom-Json
        )
    } catch {
        Backup-File $Path 'broken'
        $defaults = @(Get-Defaults)
        Save-Macros $Path $defaults
        Write-Log 'Повреждённый macros.json сохранён как резервная копия.'
        return $defaults
    }

    if ($items.Count -eq 0) {
        Backup-File $Path 'empty'
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

        $binding = Get-Binding $hotkey
        if ($binding.Hotkey -cne $hotkey) {
            $changed = $true
        }

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
        if ($hotkeys.ContainsKey([string]$macro.hotkey)) {
            throw "Комбинация '$($macro.hotkey)' назначена нескольким макросам."
        }
        $ids[[string]$macro.id] = $true
        $hotkeys[[string]$macro.hotkey] = $true
    }

    if ($changed) {
        Backup-File $Path 'before-migration'
        Save-Macros $Path @($normalized)
    }

    @($normalized)
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

function Register-All([WhamWindow]$HotkeyWindow, $State, [object[]]$Macros) {
    $oldMacros = @($State.Macros)
    Unregister-All $HotkeyWindow $State
    Start-Sleep -Milliseconds 100

    try {
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

        $State.Macros = @($Macros)
    } catch {
        $message = $_.Exception.Message
        Unregister-All $HotkeyWindow $State

        try {
            for ($index = 0; $index -lt $oldMacros.Count; $index++) {
                $macro = $oldMacros[$index]
                $binding = Get-Binding ([string]$macro.hotkey)
                $registrationId = 1001 + $index
                $HotkeyWindow.RegisterBinding(
                    $registrationId,
                    [uint32]$binding.Modifiers,
                    [uint32]$binding.Key
                )
                [void]$State.RegisteredIds.Add($registrationId)
                $State.MacroByRegistration[$registrationId] = [string]$macro.id
            }
            $State.Macros = @($oldMacros)
        } catch {}

        throw $message
    }

    Write-Status 'RUNNING' @(
        "MACROS: $($State.Macros.Count)"
        "HOTKEYS: $((@($State.Macros | ForEach-Object { $_.hotkey })) -join ', ')"
    )
}

function Run-SelfTest {
    $temporaryPath = Join-Path (
        [IO.Path]::GetTempPath()
    ) "wham-$([Guid]::NewGuid().ToString('N')).json"

    try {
        $macros = @(Get-Defaults)
        $macros[0].text = "Русский English 中文`r`nВторая строка"
        Save-Macros $temporaryPath $macros
        $loaded = @(Read-Macros $temporaryPath)

        if ($loaded.Count -ne 5) {
            throw 'Тест чтения macros.json не пройден.'
        }
        if ([string]$loaded[0].text -cne [string]$macros[0].text) {
            throw 'Тест Unicode не пройден.'
        }
        foreach ($macro in $loaded) {
            [void](Get-Binding ([string]$macro.hotkey))
        }
        'WHAM self-test passed.'
    } finally {
        Remove-Item -LiteralPath $temporaryPath -Force -ErrorAction SilentlyContinue
    }
}

function Run-App {
    $mutex = New-Object System.Threading.Mutex(
        $false,
        'Local\WHAM.QuickReplies.TextMacros'
    )
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
            ExitRequested = $false
        }

        try {
            Register-All $hotkeyWindow $state @(Read-Macros $MacrosPath)

            $hotkeyWindow.add_HotkeyPressed({
                param([int]$registrationId)

                if ($state.Busy) { return }
                $state.Busy = $true

                try {
                    $macroId = [string]$state.MacroByRegistration[$registrationId]
                    $macro = $state.Macros |
                        Where-Object { [string]$_.id -ceq $macroId } |
                        Select-Object -First 1

                    if ($null -eq $macro) {
                        throw 'Макрос не найден.'
                    }

                    Paste-Text (
                        [string]$macro.text
                    ) ([WhamWindow]::GetForegroundWindow())
                } catch {
                    Show-AppError (
                        "Не удалось вставить текст.`r`n$($_.Exception.Message)"
                    )
                } finally {
                    $state.Busy = $false
                }
            })

            $statusItem = $menu.Items.Add(
                "Активно макросов: $($state.Macros.Count)"
            )
            $statusItem.Enabled = $false

            $openItem = $menu.Items.Add('Открыть macros.json')
            $openItem.add_Click({
                Start-Process notepad.exe -ArgumentList (
                    '"{0}"' -f $MacrosPath
                )
            })

            $reloadItem = $menu.Items.Add('Перезагрузить макросы')
            $reloadItem.add_Click({
                try {
                    Register-All $hotkeyWindow $state @(Read-Macros $MacrosPath)
                    $statusItem.Text = "Активно макросов: $($state.Macros.Count)"
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
            $exitItem.add_Click({
                $state.ExitRequested = $true
                $hotkeyWindow.Close()
            })

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
