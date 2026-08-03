#requires -version 5.1
param(
    [string]$MacrosPath = (Join-Path $PSScriptRoot 'macros.json'),
    [switch]$SelfTest
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if ([Threading.Thread]::CurrentThread.ApartmentState -ne 'STA') {
    throw 'Запускайте WHAM через start-wham.cmd.'
}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$script:ErrorLog = Join-Path $PSScriptRoot 'WHAM-errors.log'
$script:StatusFile = Join-Path $PSScriptRoot 'WHAM-status.txt'
$script:Hotkeys = @(
    'Ctrl+Alt+1','Ctrl+Alt+2','Ctrl+Alt+3','Ctrl+Alt+4','Ctrl+Alt+5',
    'Ctrl+Alt+6','Ctrl+Alt+7','Ctrl+Alt+8','Ctrl+Alt+9','Shift+Tab'
)

function Write-Status([string]$Status, [string[]]$Details = @()) {
    try {
        $lines = @("STATUS: $Status", "TIME: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')", "PID: $PID") + $Details
        [IO.File]::WriteAllLines($script:StatusFile, $lines, (New-Object Text.UTF8Encoding($true)))
    } catch {}
}

function Show-Error([string]$Message) {
    try { Add-Content -LiteralPath $script:ErrorLog -Encoding UTF8 -Value "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] $Message" } catch {}
    [System.Windows.Forms.MessageBox]::Show(
        "$Message`r`n`r`nПодробности: WHAM-errors.log",
        'WHAM Quick Replies — ошибка', 'OK', 'Error'
    ) | Out-Null
}

Add-Type -ReferencedAssemblies 'System.Windows.Forms.dll','System.Drawing.dll' -TypeDefinition @'
using System;
using System.Drawing;
using System.Runtime.InteropServices;
using System.Windows.Forms;

public sealed class WhamHost : Form
{
    const int WM_HOTKEY = 0x0312;
    const uint KEYUP = 0x0002;
    const byte CTRL = 0x11;
    const byte V = 0x56;

    [DllImport("user32.dll", SetLastError=true)] static extern bool RegisterHotKey(IntPtr hWnd, int id, uint modifiers, uint key);
    [DllImport("user32.dll", SetLastError=true)] static extern bool UnregisterHotKey(IntPtr hWnd, int id);
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] [return: MarshalAs(UnmanagedType.Bool)] public static extern bool SetForegroundWindow(IntPtr hWnd);
    [DllImport("user32.dll")] [return: MarshalAs(UnmanagedType.Bool)] public static extern bool IsWindow(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern short GetAsyncKeyState(int key);
    [DllImport("user32.dll")] static extern void keybd_event(byte key, byte scan, uint flags, UIntPtr extra);

    public event Action<int> HotkeyPressed;

    public WhamHost()
    {
        ShowInTaskbar = false;
        FormBorderStyle = FormBorderStyle.FixedToolWindow;
        StartPosition = FormStartPosition.Manual;
        Location = new Point(-32000, -32000);
        Size = new Size(1, 1);
        Opacity = 0;
    }

    protected override void SetVisibleCore(bool value) { base.SetVisibleCore(false); }

    public void Register(int id, uint modifiers, uint key)
    {
        IntPtr handle = Handle;
        if (!RegisterHotKey(handle, id, modifiers, key))
            throw new InvalidOperationException("RegisterHotKey failed. Win32 error: " + Marshal.GetLastWin32Error());
    }

    public void Unregister(int id)
    {
        if (IsHandleCreated) UnregisterHotKey(Handle, id);
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
            HotkeyPressed(message.WParam.ToInt32());
        base.WndProc(ref message);
    }
}
'@

function Normalize-Hotkey([string]$Value) {
    $compact = ($Value -replace '\s', '')
    foreach ($item in $script:Hotkeys) {
        if ($compact.Equals($item, [StringComparison]::OrdinalIgnoreCase)) { return $item }
    }
    throw 'Выберите комбинацию из выпадающего списка.'
}

function Get-Binding([string]$Value) {
    $value = Normalize-Hotkey $Value
    [uint32]$mod = 0x4000
    if ($value -match '^Ctrl\+Alt\+([1-9])$') {
        $mod = $mod -bor 0x0001 -bor 0x0002
        $key = [Enum]::Parse([System.Windows.Forms.Keys], "D$($Matches[1])", $true)
    } else {
        $mod = $mod -bor 0x0004
        $key = [System.Windows.Forms.Keys]::Tab
    }
    [pscustomobject]@{ Hotkey=$value; Modifiers=[uint32]$mod; Key=[uint32]$key }
}

function Read-Macros([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "Не найден файл: $Path" }
    try { $items = @(Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json) }
    catch { throw "Не удалось прочитать macros.json.`r`n$($_.Exception.Message)" }
    if ($items.Count -eq 0) { throw 'Добавьте хотя бы один макрос.' }

    $ids = @{}; $keys = @{}
    foreach ($item in $items) {
        foreach ($name in @('id','title','hotkey','text')) {
            if (-not $item.PSObject.Properties[$name]) { throw "У макроса отсутствует поле '$name'." }
        }
        if ([string]::IsNullOrWhiteSpace([string]$item.id)) { throw 'ID макроса пуст.' }
        if ([string]::IsNullOrWhiteSpace([string]$item.title)) { throw 'Название макроса пусто.' }
        if ([string]::IsNullOrWhiteSpace([string]$item.text)) { throw "Текст макроса '$($item.title)' пуст." }
        $item.id = ([string]$item.id).Trim()
        $item.title = ([string]$item.title).Trim()
        $item.hotkey = Normalize-Hotkey ([string]$item.hotkey)
        if ($ids.ContainsKey([string]$item.id)) { throw "Повторяется ID: $($item.id)" }
        if ($keys.ContainsKey([string]$item.hotkey)) { throw "Комбинация '$($item.hotkey)' используется дважды." }
        $ids[[string]$item.id] = $true; $keys[[string]$item.hotkey] = $true
    }
    $items
}

function To-Storable($Macros) {
    @($Macros | ForEach-Object {
        [pscustomobject]@{
            id=[string]$_.id
            title=[string]$_.title
            hotkey=(Normalize-Hotkey ([string]$_.hotkey))
            text=[string]$_.text
        }
    })
}

function Save-Macros([string]$Path, $Macros) {
    $items = @(To-Storable $Macros)
    if ($items.Count -eq 0) { throw 'Нельзя сохранить пустой список.' }
    $temp = "$Path.tmp"; $backup = "$Path.bak"
    try {
        [IO.File]::WriteAllText($temp, (ConvertTo-Json $items -Depth 4), (New-Object Text.UTF8Encoding($true)))
        if (Test-Path -LiteralPath $Path) { Copy-Item $Path $backup -Force }
        Move-Item $temp $Path -Force
        $saved = @(Read-Macros $Path)
        $a = ConvertTo-Json (To-Storable $items) -Depth 4 -Compress
        $b = ConvertTo-Json (To-Storable $saved) -Depth 4 -Compress
        if ($a -cne $b) { throw 'Проверка сохранённого текста не пройдена.' }
    } catch {
        if (Test-Path -LiteralPath $backup) { Copy-Item $backup $Path -Force -ErrorAction SilentlyContinue }
        throw
    } finally { Remove-Item $temp -Force -ErrorAction SilentlyContinue }
}

function Show-Editor([string]$Path, [object[]]$Macros) {
    $items = New-Object System.Collections.ArrayList
    foreach ($m in $Macros) { [void]$items.Add([pscustomobject]@{id=[string]$m.id;title=[string]$m.title;hotkey=[string]$m.hotkey;text=[string]$m.text}) }
    $state = [pscustomobject]@{ Loading=$false; Index=-1 }

    $form = New-Object System.Windows.Forms.Form
    $form.Text='WHAM — редактор макросов'; $form.StartPosition='CenterScreen'; $form.ClientSize=New-Object System.Drawing.Size(880,600); $form.MinimumSize=New-Object System.Drawing.Size(820,560); $form.Font=New-Object System.Drawing.Font('Segoe UI',10)

    $list=New-Object System.Windows.Forms.ListBox; $list.Location=New-Object System.Drawing.Point(16,16); $list.Size=New-Object System.Drawing.Size(230,500); $list.Anchor='Top,Bottom,Left'; foreach($m in $items){[void]$list.Items.Add($m.title)}; $form.Controls.Add($list)
    $titleLabel=New-Object System.Windows.Forms.Label; $titleLabel.Text='Название'; $titleLabel.Location=New-Object System.Drawing.Point(264,18); $titleLabel.Size=New-Object System.Drawing.Size(100,24); $form.Controls.Add($titleLabel)
    $title=New-Object System.Windows.Forms.TextBox; $title.Location=New-Object System.Drawing.Point(264,43); $title.Size=New-Object System.Drawing.Size(592,27); $title.MaxLength=0; $title.Anchor='Top,Left,Right'; $form.Controls.Add($title)
    $keyLabel=New-Object System.Windows.Forms.Label; $keyLabel.Text='Комбинация клавиш'; $keyLabel.Location=New-Object System.Drawing.Point(264,82); $keyLabel.Size=New-Object System.Drawing.Size(180,24); $form.Controls.Add($keyLabel)
    $key=New-Object System.Windows.Forms.ComboBox; $key.Location=New-Object System.Drawing.Point(264,107); $key.Size=New-Object System.Drawing.Size(592,28); $key.DropDownStyle='DropDownList'; $key.Anchor='Top,Left,Right'; foreach($h in $script:Hotkeys){[void]$key.Items.Add($h)}; $form.Controls.Add($key)
    $textLabel=New-Object System.Windows.Forms.Label; $textLabel.Text='Текст вставляется без изменений'; $textLabel.Location=New-Object System.Drawing.Point(264,148); $textLabel.Size=New-Object System.Drawing.Size(300,24); $form.Controls.Add($textLabel)
    $text=New-Object System.Windows.Forms.TextBox; $text.Location=New-Object System.Drawing.Point(264,174); $text.Size=New-Object System.Drawing.Size(592,342); $text.Multiline=$true; $text.AcceptsReturn=$true; $text.AcceptsTab=$true; $text.MaxLength=0; $text.ScrollBars='Both'; $text.WordWrap=$false; $text.Anchor='Top,Bottom,Left,Right'; $form.Controls.Add($text)
    $count=New-Object System.Windows.Forms.Label; $count.Text='Символов: 0'; $count.Location=New-Object System.Drawing.Point(264,524); $count.Size=New-Object System.Drawing.Size(220,24); $count.Anchor='Bottom,Left'; $form.Controls.Add($count)
    $add=New-Object System.Windows.Forms.Button; $add.Text='Добавить'; $add.Location=New-Object System.Drawing.Point(16,542); $add.Size=New-Object System.Drawing.Size(110,34); $add.Anchor='Bottom,Left'; $form.Controls.Add($add)
    $delete=New-Object System.Windows.Forms.Button; $delete.Text='Удалить'; $delete.Location=New-Object System.Drawing.Point(136,542); $delete.Size=New-Object System.Drawing.Size(110,34); $delete.Anchor='Bottom,Left'; $form.Controls.Add($delete)
    $save=New-Object System.Windows.Forms.Button; $save.Text='Сохранить'; $save.Location=New-Object System.Drawing.Point(636,542); $save.Size=New-Object System.Drawing.Size(105,34); $save.Anchor='Bottom,Right'; $form.Controls.Add($save)
    $cancel=New-Object System.Windows.Forms.Button; $cancel.Text='Отмена'; $cancel.DialogResult=[System.Windows.Forms.DialogResult]::Cancel; $cancel.Location=New-Object System.Drawing.Point(751,542); $cancel.Size=New-Object System.Drawing.Size(105,34); $cancel.Anchor='Bottom,Right'; $form.Controls.Add($cancel); $form.CancelButton=$cancel

    $commit={
        $i=[int]$state.Index; if($state.Loading -or $i -lt 0 -or $i -ge $items.Count){return}
        $items[$i].title=[string]$title.Text; $items[$i].hotkey=[string]$key.SelectedItem; $items[$i].text=[string]$text.Text
        $caption=if([string]::IsNullOrWhiteSpace($title.Text)){'(без названия)'}else{$title.Text};$list.Items[$i]=$caption
        $count.Text="Символов: $($text.TextLength)"
    }
    $load={
        $state.Loading=$true
        try {
            $i=[int]$state.Index; $enabled=($i -ge 0 -and $i -lt $items.Count)
            $title.Enabled=$enabled; $key.Enabled=$enabled; $text.Enabled=$enabled; $delete.Enabled=$enabled
            if($enabled){$title.Text=[string]$items[$i].title; $key.SelectedItem=(Normalize-Hotkey ([string]$items[$i].hotkey)); $text.Text=[string]$items[$i].text; $count.Text="Символов: $($text.TextLength)"}
            else{$title.Clear();$key.SelectedIndex=-1;$text.Clear();$count.Text='Символов: 0'}
        } finally {$state.Loading=$false}
    }

    $list.add_SelectedIndexChanged({if($state.Loading){return};&$commit;$state.Index=[int]$list.SelectedIndex;&$load})
    $title.add_TextChanged($commit); $key.add_SelectedIndexChanged($commit); $text.add_TextChanged($commit)
    $add.add_Click({
        try {
            &$commit; $used=@{}; foreach($m in $items){$used[(Normalize-Hotkey ([string]$m.hotkey))]=$true}
            $candidate=$script:Hotkeys|Where-Object{-not $used.ContainsKey($_)}|Select-Object -First 1
            if($null -eq $candidate){throw 'Все доступные комбинации уже заняты.'}
            $m=[pscustomobject]@{id="macro-$([Guid]::NewGuid().ToString('N'))";title='Новый макрос';hotkey=[string]$candidate;text='Новый текст'}
            [void]$items.Add($m);[void]$list.Items.Add($m.title);$list.SelectedIndex=$items.Count-1
        } catch {[System.Windows.Forms.MessageBox]::Show($_.Exception.Message,'WHAM','OK','Error')|Out-Null}
    })
    $delete.add_Click({
        try {
            $i=[int]$state.Index;if($i -lt 0){return};if($items.Count -eq 1){throw 'Должен остаться хотя бы один макрос.'}
            if([System.Windows.Forms.MessageBox]::Show("Удалить '$($items[$i].title)'?",'WHAM','YesNo','Question') -ne [System.Windows.Forms.DialogResult]::Yes){return}
            $items.RemoveAt($i);$list.Items.RemoveAt($i);$state.Index=-1;$list.SelectedIndex=[Math]::Min($i,$items.Count-1)
        } catch {[System.Windows.Forms.MessageBox]::Show($_.Exception.Message,'WHAM','OK','Error')|Out-Null}
    })
    $save.add_Click({
        try {
            &$commit;$ids=@{};$keys=@{}
            for($i=0;$i -lt $items.Count;$i++){
                $m=$items[$i]
                if([string]::IsNullOrWhiteSpace([string]$m.title)-or[string]::IsNullOrWhiteSpace([string]$m.hotkey)-or[string]::IsNullOrWhiteSpace([string]$m.text)){$list.SelectedIndex=$i;throw 'Заполните название, комбинацию и текст.'}
                $m.title=([string]$m.title).Trim();$m.hotkey=Normalize-Hotkey ([string]$m.hotkey);[void](Get-Binding ([string]$m.hotkey));$id=([string]$m.id).Trim()
                if($ids.ContainsKey($id)){throw "Повторяется ID: $id"};if($keys.ContainsKey([string]$m.hotkey)){$list.SelectedIndex=$i;throw "Комбинация '$($m.hotkey)' используется дважды."}
                $ids[$id]=$true;$keys[[string]$m.hotkey]=$true
            }
            Save-Macros $Path $items;$form.DialogResult=[System.Windows.Forms.DialogResult]::OK;$form.Close()
        } catch {[System.Windows.Forms.MessageBox]::Show("Не удалось сохранить.`r`n`r`n$($_.Exception.Message)",'WHAM','OK','Error')|Out-Null}
    })

    try {if($items.Count -gt 0){$list.SelectedIndex=0};return($form.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK)} finally {$form.Dispose()}
}

function Wait-Modifiers {
    $until=[DateTime]::UtcNow.AddMilliseconds(2500)
    while([DateTime]::UtcNow -lt $until){
        $down=$false;foreach($k in @(0x10,0x11,0x12,0x5B,0x5C)){if(([WhamHost]::GetAsyncKeyState($k)-band 0x8000)-ne 0){$down=$true;break}}
        if(-not $down){return};Start-Sleep -Milliseconds 20
    }
}

function Set-Clipboard([string]$Value) {
    $last=$null
    foreach($n in 1..20){try{[System.Windows.Forms.Clipboard]::SetText($Value,[System.Windows.Forms.TextDataFormat]::UnicodeText);return}catch{$last=$_;Start-Sleep -Milliseconds 50}}
    throw "Буфер обмена недоступен: $($last.Exception.Message)"
}

function Paste-Text([string]$Value,[IntPtr]$Target) {
    Set-Clipboard $Value
    Wait-Modifiers
    if($Target -ne [IntPtr]::Zero -and [WhamHost]::IsWindow($Target)){[void][WhamHost]::SetForegroundWindow($Target);Start-Sleep -Milliseconds 140}
    [WhamHost]::Paste()
}

function Plan([object[]]$Macros) {
    $result=@();for($i=0;$i -lt $Macros.Count;$i++){$b=Get-Binding ([string]$Macros[$i].hotkey);$result += [pscustomobject]@{Id=1001+$i;Binding=$b;MacroId=[string]$Macros[$i].id;Title=[string]$Macros[$i].title}}
    $result
}

function Unregister-All([WhamHost]$Host,$State) {
    foreach($id in @($State.Registered)){$Host.Unregister([int]$id)};$State.Registered.Clear();$State.Map.Clear()
}

function Register-All([WhamHost]$Host,$State,[object[]]$Macros) {
    $new=@(Plan $Macros);$oldMacros=@($State.Macros);$old=if($oldMacros.Count){@(Plan $oldMacros)}else{@()}
    Unregister-All $Host $State;$done=New-Object System.Collections.ArrayList
    try {
        foreach($entry in $new){
            try{$Host.Register([int]$entry.Id,[uint32]$entry.Binding.Modifiers,[uint32]$entry.Binding.Key)}catch{throw "Не удалось назначить '$($entry.Binding.Hotkey)' макросу '$($entry.Title)'. Комбинация может быть занята другой программой."}
            [void]$done.Add([int]$entry.Id);[void]$State.Registered.Add([int]$entry.Id);$State.Map[[int]$entry.Id]=[string]$entry.MacroId
        }
        $State.Macros=@($Macros)
    } catch {
        $errorText=$_.Exception.Message;foreach($id in @($done)){$Host.Unregister([int]$id)};$State.Registered.Clear();$State.Map.Clear()
        try{foreach($entry in $old){$Host.Register([int]$entry.Id,[uint32]$entry.Binding.Modifiers,[uint32]$entry.Binding.Key);[void]$State.Registered.Add([int]$entry.Id);$State.Map[[int]$entry.Id]=[string]$entry.MacroId};$State.Macros=@($oldMacros)}catch{}
        throw $errorText
    }
    Write-Status 'RUNNING' @("MACROS: $($Macros.Count)","HOTKEYS: $((@($Macros|ForEach-Object{$_.hotkey})) -join ', ')","SCRIPT: $PSCommandPath")
}

if($SelfTest){
    $macros=@(Read-Macros $MacrosPath);[void](Get-Binding 'Ctrl+Alt+1');$shift=Get-Binding 'Shift+Tab';if($shift.Key -ne [uint32][System.Windows.Forms.Keys]::Tab){throw 'Shift+Tab test failed.'}
    $tmp=Join-Path ([IO.Path]::GetTempPath()) "wham-$([Guid]::NewGuid().ToString('N')).json"
    try{$long=(('Русский English 中文 😀 !@#$%^&*()[]{}<>`r`n`t'*3000)+'КОНЕЦ');$copy=@(To-Storable $macros);$copy[0].text=$long;Save-Macros $tmp $copy;$saved=@(Read-Macros $tmp);if([string]$saved[0].text -cne $long){throw 'Long Unicode test failed.'}}finally{Remove-Item "$tmp*" -Force -ErrorAction SilentlyContinue}
    $test=New-Object WhamHost;try{$test.Register(9999,[uint32](0x4000-bor 0x0001-bor 0x0002),[uint32][System.Windows.Forms.Keys]::F24);$test.Unregister(9999)}finally{$test.Dispose()}
    'WHAM self-test passed.';exit 0
}

$mutex=New-Object System.Threading.Mutex($false,'Local\WHAM.QuickReplies');$owns=$false
try{
    try{$owns=$mutex.WaitOne(0,$false)}catch[System.Threading.AbandonedMutexException]{$owns=$true}
    if(-not $owns){[System.Windows.Forms.MessageBox]::Show('WHAM уже запущен. Значок находится рядом с часами.','WHAM','OK','Information')|Out-Null;exit 0}

    $host=New-Object WhamHost;$tray=New-Object System.Windows.Forms.NotifyIcon;$menu=New-Object System.Windows.Forms.ContextMenuStrip
    $state=[pscustomobject]@{Macros=@();Registered=New-Object System.Collections.ArrayList;Map=@{};Busy=$false;Exit=$false}
    try{
        Register-All $host $state @(Read-Macros $MacrosPath)
        $host.add_HotkeyPressed({param([int]$id);if($state.Busy){return};$state.Busy=$true;try{$target=[WhamHost]::GetForegroundWindow();$macroId=[string]$state.Map[$id];$macro=$state.Macros|Where-Object{[string]$_.id -ceq $macroId}|Select-Object -First 1;if($null -eq $macro){throw 'Макрос не найден.'};Paste-Text ([string]$macro.text) $target;Write-Status 'RUNNING' @("LAST_HOTKEY: $($macro.hotkey)","LAST_TITLE: $($macro.title)","LAST_LENGTH: $(([string]$macro.text).Length)")}catch{Show-Error "Не удалось вставить текст.`r`n$($_.Exception.Message)"}finally{$state.Busy=$false}})
        $status=$menu.Items.Add("Готово: $($state.Macros.Count) комбинаций активно");$status.Enabled=$false
        $editor=$menu.Items.Add('Редактор макросов...');$editor.add_Click({if($state.Busy){return};$state.Busy=$true;try{$before=@(Read-Macros $MacrosPath);if(Show-Editor $MacrosPath $before){try{$after=@(Read-Macros $MacrosPath);Register-All $host $state $after;$status.Text="Готово: $($state.Macros.Count) комбинаций активно";$tray.ShowBalloonTip(1600,'WHAM','Макросы и комбинации сохранены.','Info')}catch{if(Test-Path "$MacrosPath.bak"){Copy-Item "$MacrosPath.bak" $MacrosPath -Force};Register-All $host $state $before;throw}}}catch{Show-Error "Не удалось обновить макросы.`r`n$($_.Exception.Message)"}finally{$state.Busy=$false}})
        $reload=$menu.Items.Add('Перезагрузить комбинации');$reload.add_Click({try{Register-All $host $state @(Read-Macros $MacrosPath);$status.Text="Готово: $($state.Macros.Count) комбинаций активно"}catch{Show-Error $_.Exception.Message}})
        $open=$menu.Items.Add('Открыть macros.json');$open.add_Click({Start-Process notepad.exe -ArgumentList ('"{0}"'-f$MacrosPath)})
        $diag=$menu.Items.Add('Открыть диагностику');$diag.add_Click({Start-Process notepad.exe -ArgumentList ('"{0}"'-f$script:StatusFile)})
        [void]$menu.Items.Add('-');$exit=$menu.Items.Add('Выход');$exit.add_Click({$state.Exit=$true;$host.Close()})
        $tray.Icon=[System.Drawing.SystemIcons]::Information;$tray.Text='WHAM Quick Replies — работает';$tray.ContextMenuStrip=$menu;$tray.Visible=$true;$tray.ShowBalloonTip(2000,'WHAM',"$($state.Macros.Count) комбинаций активны. Программа работает в фоне.",'Info')
        [System.Windows.Forms.Application]::Run($host)
    }finally{Write-Status $(if($state.Exit){'STOPPED_BY_USER'}else{'STOPPED'}) @("SCRIPT: $PSCommandPath");$tray.Visible=$false;$tray.Dispose();$menu.Dispose();Unregister-All $host $state;$host.Dispose()}
}catch{if($SelfTest){throw};Write-Status 'ERROR' @("ERROR: $($_.Exception.Message)");Show-Error $_.Exception.Message;exit 1}
finally{if($owns){try{$mutex.ReleaseMutex()}catch{}};$mutex.Dispose()}
