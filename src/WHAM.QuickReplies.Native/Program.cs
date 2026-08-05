using System.Diagnostics;
using System.Drawing;
using System.Runtime.InteropServices;
using System.Text.Encodings.Web;
using System.Text.Json;
using System.Text.RegularExpressions;
using System.Windows.Forms;

namespace WHAM.QuickReplies.Native;

internal static class Program
{
    internal const string ProductName = "WHAM Quick Replies";
    internal const string Version = "0.10.0-native-test1";
    internal static readonly string BaseDirectory = AppContext.BaseDirectory;
    internal static readonly string MacroPath = Path.Combine(BaseDirectory, "macros.json");
    internal static readonly string ErrorLogPath = Path.Combine(BaseDirectory, "WHAM-errors.log");

    [STAThread]
    private static void Main()
    {
        using var mutex = new Mutex(false, @"Local\WHAM.QuickReplies.Native", out _);
        var ownsMutex = false;

        try
        {
            try
            {
                ownsMutex = mutex.WaitOne(TimeSpan.Zero, false);
            }
            catch (AbandonedMutexException)
            {
                ownsMutex = true;
            }

            if (!ownsMutex)
            {
                MessageBox.Show(
                    "WHAM Quick Replies уже запущен. Значок приложения находится рядом с часами.",
                    ProductName,
                    MessageBoxButtons.OK,
                    MessageBoxIcon.Information);
                return;
            }

            ApplicationConfiguration.Initialize();
            Application.Run(new TrayApplicationContext());
        }
        catch (Exception exception)
        {
            LogException(exception);
            MessageBox.Show(
                $"Не удалось запустить {ProductName}.\r\n\r\n{exception.Message}\r\n\r\nПодробности: {ErrorLogPath}",
                $"{ProductName} — ошибка",
                MessageBoxButtons.OK,
                MessageBoxIcon.Error);
        }
        finally
        {
            if (ownsMutex)
            {
                try { mutex.ReleaseMutex(); } catch { }
            }
        }
    }

    internal static void LogException(Exception exception)
    {
        try
        {
            File.AppendAllText(
                ErrorLogPath,
                $"[{DateTime.Now:yyyy-MM-dd HH:mm:ss}] {exception}\r\n\r\n");
        }
        catch
        {
            // Logging must never hide the original error.
        }
    }
}

internal sealed class TrayApplicationContext : ApplicationContext
{
    private readonly NotifyIcon _notifyIcon;
    private readonly HotkeyWindow _hotkeyWindow;
    private readonly ToolStripMenuItem _statusItem;
    private List<MacroItem> _macros;
    private bool _busy;

    internal TrayApplicationContext()
    {
        _macros = MacroStore.LoadOrCreate(Program.MacroPath);
        _hotkeyWindow = new HotkeyWindow();
        _hotkeyWindow.HotkeyPressed += OnHotkeyPressed;

        var menu = new ContextMenuStrip();
        _statusItem = new ToolStripMenuItem { Enabled = false };
        menu.Items.Add(_statusItem);
        menu.Items.Add("Редактор макросов...", null, (_, _) => OpenEditor());
        menu.Items.Add("Перезагрузить macros.json", null, (_, _) => ReloadMacros(showConfirmation: true));
        menu.Items.Add("Открыть папку приложения", null, (_, _) => OpenApplicationFolder());
        menu.Items.Add(new ToolStripSeparator());
        menu.Items.Add($"Версия {Program.Version}") { Enabled = false };
        menu.Items.Add("Выход", null, (_, _) => ExitThread());

        _notifyIcon = new NotifyIcon
        {
            Icon = SystemIcons.Information,
            Text = $"{Program.ProductName} {Program.Version}",
            ContextMenuStrip = menu,
            Visible = true
        };
        _notifyIcon.DoubleClick += (_, _) => OpenEditor();

        ReloadMacros(showConfirmation: false);
        _notifyIcon.ShowBalloonTip(
            1800,
            Program.ProductName,
            $"Активно макросов: {_macros.Count}. Для проверки откройте Блокнот и нажмите Ctrl+Alt+1.",
            ToolTipIcon.Info);
    }

    private void OnHotkeyPressed(MacroItem macro)
    {
        if (_busy)
        {
            return;
        }

        _busy = true;
        try
        {
            SetClipboardText(macro.Text);
            SendKeys.SendWait("^v");
        }
        catch (Exception exception)
        {
            Program.LogException(exception);
            _notifyIcon.ShowBalloonTip(
                2500,
                $"{Program.ProductName} — ошибка",
                exception.Message,
                ToolTipIcon.Error);
        }
        finally
        {
            _busy = false;
        }
    }

    private static void SetClipboardText(string text)
    {
        Exception? lastError = null;
        for (var attempt = 0; attempt < 20; attempt++)
        {
            try
            {
                Clipboard.SetText(text, TextDataFormat.UnicodeText);
                return;
            }
            catch (Exception exception)
            {
                lastError = exception;
                Thread.Sleep(50);
            }
        }

        throw new InvalidOperationException(
            $"Не удалось получить доступ к буферу обмена. {lastError?.Message}",
            lastError);
    }

    private void OpenEditor()
    {
        if (_busy)
        {
            return;
        }

        _busy = true;
        try
        {
            using var editor = new MacroEditorForm(_macros);
            if (editor.ShowDialog() != DialogResult.OK)
            {
                return;
            }

            MacroStore.Save(Program.MacroPath, editor.Result);
            ReloadMacros(showConfirmation: false);
            _notifyIcon.ShowBalloonTip(
                1500,
                Program.ProductName,
                "Макросы сохранены. Горячие клавиши обновлены.",
                ToolTipIcon.Info);
        }
        catch (Exception exception)
        {
            Program.LogException(exception);
            MessageBox.Show(
                $"Не удалось сохранить макросы.\r\n\r\n{exception.Message}",
                Program.ProductName,
                MessageBoxButtons.OK,
                MessageBoxIcon.Error);
        }
        finally
        {
            _busy = false;
        }
    }

    private void ReloadMacros(bool showConfirmation)
    {
        try
        {
            var loaded = MacroStore.LoadOrCreate(Program.MacroPath);
            _hotkeyWindow.RegisterAll(loaded);
            _macros = loaded;
            _statusItem.Text = $"Готово: {_macros.Count} макросов активно";

            if (showConfirmation)
            {
                _notifyIcon.ShowBalloonTip(
                    1300,
                    Program.ProductName,
                    "Файл macros.json перечитан.",
                    ToolTipIcon.Info);
            }
        }
        catch (Exception exception)
        {
            Program.LogException(exception);
            MessageBox.Show(
                $"Не удалось загрузить макросы.\r\n\r\n{exception.Message}",
                Program.ProductName,
                MessageBoxButtons.OK,
                MessageBoxIcon.Error);
        }
    }

    private static void OpenApplicationFolder()
    {
        Process.Start(new ProcessStartInfo
        {
            FileName = "explorer.exe",
            Arguments = $"\"{Program.BaseDirectory}\"",
            UseShellExecute = true
        });
    }

    protected override void ExitThreadCore()
    {
        _notifyIcon.Visible = false;
        _notifyIcon.Dispose();
        _hotkeyWindow.Dispose();
        base.ExitThreadCore();
    }
}

internal sealed class HotkeyWindow : NativeWindow, IDisposable
{
    private const int WmHotkey = 0x0312;
    private const uint ModAlt = 0x0001;
    private const uint ModControl = 0x0002;
    private const uint ModNoRepeat = 0x4000;

    private readonly Dictionary<int, MacroItem> _registered = new();

    internal event Action<MacroItem>? HotkeyPressed;

    internal HotkeyWindow()
    {
        CreateHandle(new CreateParams());
    }

    internal void RegisterAll(IReadOnlyList<MacroItem> macros)
    {
        UnregisterAll();
        var registeredIds = new List<int>();

        try
        {
            for (var index = 0; index < macros.Count; index++)
            {
                var macro = macros[index];
                var definition = HotkeyDefinition.Parse(macro.Hotkey);
                var id = 1001 + index;

                if (!RegisterHotKey(Handle, id, definition.Modifiers, definition.Key))
                {
                    throw new InvalidOperationException(
                        $"Комбинация '{macro.Hotkey}' для макроса '{macro.Title}' занята другой программой.");
                }

                registeredIds.Add(id);
                _registered[id] = macro;
            }
        }
        catch
        {
            foreach (var id in registeredIds)
            {
                UnregisterHotKey(Handle, id);
            }
            _registered.Clear();
            throw;
        }
    }

    private void UnregisterAll()
    {
        foreach (var id in _registered.Keys.ToArray())
        {
            UnregisterHotKey(Handle, id);
        }
        _registered.Clear();
    }

    protected override void WndProc(ref Message message)
    {
        if (message.Msg == WmHotkey && _registered.TryGetValue(message.WParam.ToInt32(), out var macro))
        {
            HotkeyPressed?.Invoke(macro);
        }

        base.WndProc(ref message);
    }

    public void Dispose()
    {
        UnregisterAll();
        DestroyHandle();
        GC.SuppressFinalize(this);
    }

    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool RegisterHotKey(IntPtr windowHandle, int id, uint modifiers, uint virtualKey);

    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool UnregisterHotKey(IntPtr windowHandle, int id);

    internal readonly record struct HotkeyDefinition(uint Modifiers, uint Key)
    {
        private static readonly Regex Pattern = new(
            "^Ctrl\\+Alt\\+([1-9])$",
            RegexOptions.Compiled | RegexOptions.IgnoreCase | RegexOptions.CultureInvariant);

        internal static HotkeyDefinition Parse(string value)
        {
            var normalized = MacroStore.NormalizeHotkey(value);
            var match = Pattern.Match(normalized);
            if (!match.Success)
            {
                throw new InvalidOperationException(
                    $"Неподдерживаемая комбинация '{value}'. В этой версии доступны Ctrl+Alt+1 — Ctrl+Alt+9.");
            }

            var digit = int.Parse(match.Groups[1].Value);
            return new HotkeyDefinition(ModControl | ModAlt | ModNoRepeat, (uint)((int)Keys.D0 + digit));
        }
    }
}

internal sealed class MacroEditorForm : Form
{
    private readonly List<MacroItem> _items;
    private readonly ListBox _list = new();
    private readonly TextBox _title = new();
    private readonly ComboBox _hotkey = new();
    private readonly TextBox _text = new();
    private int _currentIndex = -1;
    private bool _loading;

    internal IReadOnlyList<MacroItem> Result => _items.Select(item => item.Clone()).ToList();

    internal MacroEditorForm(IEnumerable<MacroItem> macros)
    {
        _items = macros.Select(item => item.Clone()).ToList();

        Text = $"{Program.ProductName} — редактор";
        StartPosition = FormStartPosition.CenterScreen;
        ClientSize = new Size(850, 570);
        MinimumSize = new Size(780, 520);
        Font = new Font("Segoe UI", 10F);

        _list.SetBounds(14, 14, 235, 485);
        _list.Anchor = AnchorStyles.Top | AnchorStyles.Bottom | AnchorStyles.Left;
        _list.SelectedIndexChanged += (_, _) => ChangeSelection(_list.SelectedIndex);
        Controls.Add(_list);

        Controls.Add(CreateLabel("Название", 267, 16, 120));
        _title.SetBounds(267, 42, 566, 28);
        _title.Anchor = AnchorStyles.Top | AnchorStyles.Left | AnchorStyles.Right;
        _title.TextChanged += (_, _) => UpdateCurrentTitle();
        Controls.Add(_title);

        Controls.Add(CreateLabel("Горячая клавиша", 267, 82, 170));
        _hotkey.SetBounds(267, 108, 566, 30);
        _hotkey.Anchor = AnchorStyles.Top | AnchorStyles.Left | AnchorStyles.Right;
        _hotkey.DropDownStyle = ComboBoxStyle.DropDownList;
        for (var digit = 1; digit <= 9; digit++)
        {
            _hotkey.Items.Add($"Ctrl+Alt+{digit}");
        }
        Controls.Add(_hotkey);

        Controls.Add(CreateLabel("Текст макроса", 267, 150, 170));
        _text.SetBounds(267, 176, 566, 323);
        _text.Anchor = AnchorStyles.Top | AnchorStyles.Bottom | AnchorStyles.Left | AnchorStyles.Right;
        _text.Multiline = true;
        _text.AcceptsReturn = true;
        _text.AcceptsTab = true;
        _text.ScrollBars = ScrollBars.Both;
        _text.WordWrap = false;
        Controls.Add(_text);

        var addButton = CreateButton("Добавить", 14, 516, 112);
        addButton.Anchor = AnchorStyles.Bottom | AnchorStyles.Left;
        addButton.Click += (_, _) => AddMacro();
        Controls.Add(addButton);

        var deleteButton = CreateButton("Удалить", 137, 516, 112);
        deleteButton.Anchor = AnchorStyles.Bottom | AnchorStyles.Left;
        deleteButton.Click += (_, _) => DeleteMacro();
        Controls.Add(deleteButton);

        var saveButton = CreateButton("Сохранить", 602, 516, 110);
        saveButton.Anchor = AnchorStyles.Bottom | AnchorStyles.Right;
        saveButton.Click += (_, _) => SaveAndClose();
        Controls.Add(saveButton);

        var cancelButton = CreateButton("Отмена", 723, 516, 110);
        cancelButton.Anchor = AnchorStyles.Bottom | AnchorStyles.Right;
        cancelButton.DialogResult = DialogResult.Cancel;
        Controls.Add(cancelButton);
        CancelButton = cancelButton;

        RefreshList();
        if (_items.Count > 0)
        {
            _list.SelectedIndex = 0;
        }
    }

    private static Label CreateLabel(string text, int x, int y, int width) => new()
    {
        Text = text,
        Location = new Point(x, y),
        Size = new Size(width, 24)
    };

    private static Button CreateButton(string text, int x, int y, int width) => new()
    {
        Text = text,
        Location = new Point(x, y),
        Size = new Size(width, 36)
    };

    private void RefreshList()
    {
        _loading = true;
        try
        {
            _list.Items.Clear();
            foreach (var macro in _items)
            {
                _list.Items.Add(string.IsNullOrWhiteSpace(macro.Title) ? "(без названия)" : macro.Title);
            }
        }
        finally
        {
            _loading = false;
        }
    }

    private void ChangeSelection(int newIndex)
    {
        if (_loading)
        {
            return;
        }

        CommitCurrent();
        _currentIndex = newIndex;
        LoadCurrent();
    }

    private void CommitCurrent()
    {
        if (_loading || _currentIndex < 0 || _currentIndex >= _items.Count)
        {
            return;
        }

        _items[_currentIndex].Title = _title.Text;
        _items[_currentIndex].Hotkey = _hotkey.SelectedItem?.ToString() ?? string.Empty;
        _items[_currentIndex].Text = _text.Text;
    }

    private void LoadCurrent()
    {
        _loading = true;
        try
        {
            var enabled = _currentIndex >= 0 && _currentIndex < _items.Count;
            _title.Enabled = enabled;
            _hotkey.Enabled = enabled;
            _text.Enabled = enabled;

            if (!enabled)
            {
                _title.Clear();
                _hotkey.SelectedIndex = -1;
                _text.Clear();
                return;
            }

            var item = _items[_currentIndex];
            _title.Text = item.Title;
            _hotkey.SelectedItem = MacroStore.NormalizeHotkey(item.Hotkey);
            _text.Text = item.Text;
        }
        finally
        {
            _loading = false;
        }
    }

    private void UpdateCurrentTitle()
    {
        if (_loading || _currentIndex < 0 || _currentIndex >= _items.Count)
        {
            return;
        }

        var caption = string.IsNullOrWhiteSpace(_title.Text) ? "(без названия)" : _title.Text;
        _list.Items[_currentIndex] = caption;
    }

    private void AddMacro()
    {
        CommitCurrent();
        var used = _items.Select(item => MacroStore.NormalizeHotkey(item.Hotkey)).ToHashSet(StringComparer.OrdinalIgnoreCase);
        var hotkey = Enumerable.Range(1, 9)
            .Select(digit => $"Ctrl+Alt+{digit}")
            .FirstOrDefault(candidate => !used.Contains(candidate));

        if (hotkey is null)
        {
            MessageBox.Show(
                "Все доступные комбинации Ctrl+Alt+1 — Ctrl+Alt+9 уже заняты.",
                Program.ProductName,
                MessageBoxButtons.OK,
                MessageBoxIcon.Information);
            return;
        }

        _items.Add(new MacroItem
        {
            Id = $"macro-{Guid.NewGuid():N}",
            Title = "Новый макрос",
            Hotkey = hotkey,
            Text = "Новый текст"
        });
        RefreshList();
        _list.SelectedIndex = _items.Count - 1;
    }

    private void DeleteMacro()
    {
        if (_currentIndex < 0 || _currentIndex >= _items.Count)
        {
            return;
        }

        if (_items.Count == 1)
        {
            MessageBox.Show(
                "Должен остаться хотя бы один макрос.",
                Program.ProductName,
                MessageBoxButtons.OK,
                MessageBoxIcon.Information);
            return;
        }

        var title = _items[_currentIndex].Title;
        if (MessageBox.Show(
                $"Удалить макрос '{title}'?",
                Program.ProductName,
                MessageBoxButtons.YesNo,
                MessageBoxIcon.Question) != DialogResult.Yes)
        {
            return;
        }

        var oldIndex = _currentIndex;
        _items.RemoveAt(oldIndex);
        _currentIndex = -1;
        RefreshList();
        _list.SelectedIndex = Math.Min(oldIndex, _items.Count - 1);
    }

    private void SaveAndClose()
    {
        CommitCurrent();

        try
        {
            MacroStore.Validate(_items);
            DialogResult = DialogResult.OK;
            Close();
        }
        catch (Exception exception)
        {
            MessageBox.Show(
                exception.Message,
                Program.ProductName,
                MessageBoxButtons.OK,
                MessageBoxIcon.Error);
        }
    }
}

internal sealed class MacroItem
{
    public string Id { get; set; } = string.Empty;
    public string Title { get; set; } = string.Empty;
    public string Hotkey { get; set; } = string.Empty;
    public string Text { get; set; } = string.Empty;

    internal MacroItem Clone() => new()
    {
        Id = Id,
        Title = Title,
        Hotkey = Hotkey,
        Text = Text
    };
}

internal static class MacroStore
{
    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        WriteIndented = true,
        Encoder = JavaScriptEncoder.UnsafeRelaxedJsonEscaping,
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase
    };

    internal static List<MacroItem> LoadOrCreate(string path)
    {
        if (!File.Exists(path))
        {
            var defaults = CreateDefaults();
            Save(path, defaults, createBackup: false);
            return defaults;
        }

        try
        {
            var original = File.ReadAllText(path);
            using var document = JsonDocument.Parse(original);
            if (document.RootElement.ValueKind != JsonValueKind.Array)
            {
                throw new InvalidDataException("Файл macros.json должен содержать JSON-массив.");
            }

            var result = new List<MacroItem>();
            var index = 0;
            foreach (var element in document.RootElement.EnumerateArray())
            {
                index++;
                if (element.ValueKind != JsonValueKind.Object)
                {
                    continue;
                }

                result.Add(new MacroItem
                {
                    Id = FirstString(element, "id") ?? $"macro-{Guid.NewGuid():N}",
                    Title = FirstString(element, "title", "name") ?? $"Макрос {index}",
                    Hotkey = FirstString(element, "hotkey", "shortcut") ?? $"Ctrl+Alt+{Math.Min(index, 9)}",
                    Text = FirstString(element, "text", "content", "template") ?? string.Empty
                });
            }

            if (result.Count == 0)
            {
                result = CreateDefaults();
            }

            Normalize(result);
            Validate(result);

            var normalized = JsonSerializer.Serialize(result, JsonOptions);
            if (!JsonEquivalent(original, normalized))
            {
                Save(path, result, createBackup: true);
            }

            return result;
        }
        catch (Exception exception)
        {
            Program.LogException(exception);
            BackupFile(path, "corrupt");
            var defaults = CreateDefaults();
            Save(path, defaults, createBackup: false);
            return defaults;
        }
    }

    internal static void Save(string path, IEnumerable<MacroItem> macros, bool createBackup = true)
    {
        var normalized = macros.Select(item => item.Clone()).ToList();
        Normalize(normalized);
        Validate(normalized);

        Directory.CreateDirectory(Path.GetDirectoryName(path) ?? Program.BaseDirectory);
        var temporaryPath = path + ".tmp";

        try
        {
            if (createBackup && File.Exists(path))
            {
                BackupFile(path, "backup");
            }

            File.WriteAllText(temporaryPath, JsonSerializer.Serialize(normalized, JsonOptions));
            File.Move(temporaryPath, path, true);
        }
        finally
        {
            if (File.Exists(temporaryPath))
            {
                File.Delete(temporaryPath);
            }
        }
    }

    internal static void Validate(IReadOnlyCollection<MacroItem> macros)
    {
        if (macros.Count == 0)
        {
            throw new InvalidDataException("Добавьте хотя бы один макрос.");
        }

        var ids = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        var hotkeys = new HashSet<string>(StringComparer.OrdinalIgnoreCase);

        foreach (var macro in macros)
        {
            if (string.IsNullOrWhiteSpace(macro.Id))
            {
                throw new InvalidDataException("У одного из макросов отсутствует ID.");
            }
            if (string.IsNullOrWhiteSpace(macro.Title))
            {
                throw new InvalidDataException("У одного из макросов отсутствует название.");
            }
            if (string.IsNullOrWhiteSpace(macro.Text))
            {
                throw new InvalidDataException($"Текст макроса '{macro.Title}' пуст.");
            }

            _ = HotkeyWindow.HotkeyDefinition.Parse(macro.Hotkey);

            if (!ids.Add(macro.Id))
            {
                throw new InvalidDataException($"Повторяется ID макроса: {macro.Id}");
            }
            if (!hotkeys.Add(macro.Hotkey))
            {
                throw new InvalidDataException($"Комбинация '{macro.Hotkey}' используется дважды.");
            }
        }
    }

    internal static string NormalizeHotkey(string value)
    {
        var compact = Regex.Replace(value ?? string.Empty, "\\s+", string.Empty);
        var match = Regex.Match(
            compact,
            "^ctrl\\+alt\\+([1-9])$",
            RegexOptions.IgnoreCase | RegexOptions.CultureInvariant);

        return match.Success ? $"Ctrl+Alt+{match.Groups[1].Value}" : compact;
    }

    private static void Normalize(List<MacroItem> macros)
    {
        var usedHotkeys = new HashSet<string>(StringComparer.OrdinalIgnoreCase);

        for (var index = 0; index < macros.Count; index++)
        {
            var macro = macros[index];
            macro.Id = string.IsNullOrWhiteSpace(macro.Id) ? $"macro-{Guid.NewGuid():N}" : macro.Id.Trim();
            macro.Title = string.IsNullOrWhiteSpace(macro.Title) ? $"Макрос {index + 1}" : macro.Title.Trim();
            macro.Text ??= string.Empty;
            macro.Hotkey = NormalizeHotkey(macro.Hotkey);

            var valid = Regex.IsMatch(
                macro.Hotkey,
                "^Ctrl\\+Alt\\+[1-9]$",
                RegexOptions.CultureInvariant);

            if (!valid || !usedHotkeys.Add(macro.Hotkey))
            {
                macro.Hotkey = Enumerable.Range(1, 9)
                    .Select(digit => $"Ctrl+Alt+{digit}")
                    .FirstOrDefault(candidate => usedHotkeys.Add(candidate))
                    ?? throw new InvalidDataException("Поддерживается не более девяти макросов в одной сборке.");
            }
        }
    }

    private static List<MacroItem> CreateDefaults() =>
    [
        new MacroItem
        {
            Id = "macro-1",
            Title = "Проверка WHAM",
            Hotkey = "Ctrl+Alt+1",
            Text = "Добрый день! Макрос WHAM работает."
        },
        new MacroItem
        {
            Id = "macro-2",
            Title = "Заявка принята",
            Hotkey = "Ctrl+Alt+2",
            Text = "Добрый день! Заявка принята в работу."
        },
        new MacroItem
        {
            Id = "macro-3",
            Title = "Не хватает данных",
            Hotkey = "Ctrl+Alt+3",
            Text = "Добрый день! Для продолжения работы не хватает данных."
        }
    ];

    private static string? FirstString(JsonElement element, params string[] names)
    {
        foreach (var property in element.EnumerateObject())
        {
            if (names.Any(name => property.Name.Equals(name, StringComparison.OrdinalIgnoreCase)) &&
                property.Value.ValueKind == JsonValueKind.String)
            {
                return property.Value.GetString();
            }
        }

        return null;
    }

    private static void BackupFile(string path, string label)
    {
        try
        {
            if (!File.Exists(path))
            {
                return;
            }

            var backupPath = Path.Combine(
                Path.GetDirectoryName(path) ?? Program.BaseDirectory,
                $"macros.{label}.{DateTime.Now:yyyyMMdd-HHmmss}.json");
            File.Copy(path, backupPath, false);
        }
        catch
        {
            // A failed backup must not prevent application recovery.
        }
    }

    private static bool JsonEquivalent(string left, string right)
    {
        try
        {
            using var leftDocument = JsonDocument.Parse(left);
            using var rightDocument = JsonDocument.Parse(right);
            return JsonSerializer.Serialize(leftDocument.RootElement) ==
                   JsonSerializer.Serialize(rightDocument.RootElement);
        }
        catch
        {
            return false;
        }
    }
}
