using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text.Encodings.Web;
using System.Text.Json;
using System.Text.RegularExpressions;
using System.Windows.Forms;

namespace WHAM.QuickReplies.Native;

internal static class NativeProgram
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
                    "WHAM Quick Replies уже запущен. Значок находится рядом с часами.",
                    ProductName,
                    MessageBoxButtons.OK,
                    MessageBoxIcon.Information);
                return;
            }

            ApplicationConfiguration.Initialize();
            Application.Run(new NativeTrayContext());
        }
        catch (Exception exception)
        {
            Log(exception);
            MessageBox.Show(
                $"Не удалось запустить {ProductName}.\r\n\r\n{exception.Message}\r\n\r\nЖурнал: {ErrorLogPath}",
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

    internal static void Log(Exception exception)
    {
        try
        {
            File.AppendAllText(
                ErrorLogPath,
                $"[{DateTime.Now:yyyy-MM-dd HH:mm:ss}] {exception}\r\n\r\n");
        }
        catch
        {
            // Logging must not mask the original error.
        }
    }
}

internal sealed class NativeTrayContext : ApplicationContext
{
    private readonly NotifyIcon _tray;
    private readonly HotkeyReceiver _hotkeys;
    private readonly ToolStripMenuItem _status;
    private IReadOnlyList<TextMacro> _macros = Array.Empty<TextMacro>();
    private bool _busy;

    internal NativeTrayContext()
    {
        _hotkeys = new HotkeyReceiver();
        _hotkeys.MacroPressed += PasteMacro;

        var menu = new ContextMenuStrip();
        _status = new ToolStripMenuItem { Enabled = false };
        menu.Items.Add(_status);
        menu.Items.Add("Открыть macros.json", null, (_, _) => OpenMacroFile());
        menu.Items.Add("Перезагрузить макросы", null, (_, _) => Reload(showConfirmation: true));
        menu.Items.Add("Открыть папку приложения", null, (_, _) => OpenApplicationFolder());
        menu.Items.Add(new ToolStripSeparator());
        var versionItem = new ToolStripMenuItem($"Версия {NativeProgram.Version}") { Enabled = false };
        menu.Items.Add(versionItem);
        menu.Items.Add("Выход", null, (_, _) => ExitThread());

        _tray = new NotifyIcon
        {
            Icon = System.Drawing.SystemIcons.Information,
            Text = $"{NativeProgram.ProductName} {NativeProgram.Version}",
            ContextMenuStrip = menu,
            Visible = true
        };
        _tray.DoubleClick += (_, _) => OpenMacroFile();

        Reload(showConfirmation: false);
        _tray.ShowBalloonTip(
            1800,
            NativeProgram.ProductName,
            "Откройте Блокнот и нажмите Ctrl+Alt+1.",
            ToolTipIcon.Info);
    }

    private void Reload(bool showConfirmation)
    {
        try
        {
            var loaded = MacroFile.LoadOrCreate(NativeProgram.MacroPath);
            _hotkeys.ReplaceAll(loaded);
            _macros = loaded;
            _status.Text = $"Готово: {_macros.Count} макросов активно";

            if (showConfirmation)
            {
                _tray.ShowBalloonTip(
                    1200,
                    NativeProgram.ProductName,
                    "Файл macros.json перечитан.",
                    ToolTipIcon.Info);
            }
        }
        catch (Exception exception)
        {
            NativeProgram.Log(exception);
            MessageBox.Show(
                $"Не удалось загрузить макросы.\r\n\r\n{exception.Message}",
                NativeProgram.ProductName,
                MessageBoxButtons.OK,
                MessageBoxIcon.Error);
        }
    }

    private void PasteMacro(TextMacro macro)
    {
        if (_busy)
        {
            return;
        }

        _busy = true;
        try
        {
            WaitForModifierRelease();
            if (!KeyboardInput.TryTypeUnicode(macro.Text))
            {
                PasteWithClipboardPreserved(macro.Text);
            }
        }
        catch (Exception exception)
        {
            NativeProgram.Log(exception);
            _tray.ShowBalloonTip(
                2200,
                $"{NativeProgram.ProductName} — ошибка",
                exception.Message,
                ToolTipIcon.Error);
        }
        finally
        {
            _busy = false;
        }
    }

    private static void WaitForModifierRelease()
    {
        var deadline = DateTime.UtcNow.AddSeconds(2);
        while (DateTime.UtcNow < deadline)
        {
            if (!KeyboardInput.AnyModifierDown())
            {
                return;
            }
            Thread.Sleep(20);
        }
    }

    private static void PasteWithClipboardPreserved(string text)
    {
        var snapshot = CaptureClipboard();
        try
        {
            SetClipboardText(text);
            KeyboardInput.Paste();

            // Ctrl+V is queued to the foreground application. Give it a brief
            // window to read the temporary clipboard before restoring the user data.
            Thread.Sleep(150);
        }
        finally
        {
            RestoreClipboard(snapshot);
        }
    }

    private static DataObject? CaptureClipboard()
    {
        var source = Clipboard.GetDataObject();
        if (source is null)
        {
            return null;
        }

        var snapshot = new DataObject();
        foreach (var format in source.GetFormats(autoConvert: false))
        {
            try
            {
                var value = source.GetData(format, autoConvert: false);
                if (value is not null)
                {
                    snapshot.SetData(format, autoConvert: false, value);
                }
            }
            catch
            {
                // A provider can expose a transient/custom format that cannot be
                // materialized. Preserve every format that can be safely copied.
            }
        }

        return snapshot;
    }

    private static void SetClipboardText(string text)
    {
        SetClipboardData(() => Clipboard.SetText(text, TextDataFormat.UnicodeText));
    }

    private static void RestoreClipboard(DataObject? snapshot)
    {
        SetClipboardData(() =>
        {
            if (snapshot is null || snapshot.GetFormats(autoConvert: false).Length == 0)
            {
                Clipboard.Clear();
                return;
            }

            Clipboard.SetDataObject(snapshot, copy: true);
        });
    }

    private static void SetClipboardData(Action action)
    {
        Exception? lastError = null;
        for (var attempt = 0; attempt < 20; attempt++)
        {
            try
            {
                action();
                return;
            }
            catch (Exception exception)
            {
                lastError = exception;
                Thread.Sleep(50);
            }
        }

        throw new InvalidOperationException(
            $"Буфер обмена недоступен. {lastError?.Message}",
            lastError);
    }

    private static void OpenMacroFile()
    {
        if (!File.Exists(NativeProgram.MacroPath))
        {
            MacroFile.LoadOrCreate(NativeProgram.MacroPath);
        }

        Process.Start(new ProcessStartInfo
        {
            FileName = NativeProgram.MacroPath,
            UseShellExecute = true
        });
    }

    private static void OpenApplicationFolder()
    {
        Process.Start(new ProcessStartInfo
        {
            FileName = "explorer.exe",
            Arguments = $"\"{NativeProgram.BaseDirectory}\"",
            UseShellExecute = true
        });
    }

    protected override void ExitThreadCore()
    {
        _tray.Visible = false;
        _tray.Dispose();
        _hotkeys.Dispose();
        base.ExitThreadCore();
    }
}

internal sealed class HotkeyReceiver : NativeWindow, IDisposable
{
    private const int WmHotkey = 0x0312;
    private const uint ModAlt = 0x0001;
    private const uint ModControl = 0x0002;
    private const uint ModNoRepeat = 0x4000;

    private readonly Dictionary<int, TextMacro> _registered = new();
    private IReadOnlyList<TextMacro> _current = Array.Empty<TextMacro>();

    internal event Action<TextMacro>? MacroPressed;

    internal HotkeyReceiver()
    {
        CreateHandle(new CreateParams());
    }

    internal void ReplaceAll(IReadOnlyList<TextMacro> macros)
    {
        var previous = _current.Select(item => item.Clone()).ToList();
        UnregisterAll();

        try
        {
            RegisterList(macros);
            _current = macros.Select(item => item.Clone()).ToList();
        }
        catch
        {
            UnregisterAll();
            if (previous.Count > 0)
            {
                try
                {
                    RegisterList(previous);
                    _current = previous;
                }
                catch
                {
                    _current = Array.Empty<TextMacro>();
                }
            }
            throw;
        }
    }

    private void RegisterList(IReadOnlyList<TextMacro> macros)
    {
        for (var index = 0; index < macros.Count; index++)
        {
            var macro = macros[index];
            var binding = ParseHotkey(macro.Hotkey);
            var id = 1001 + index;

            if (!RegisterHotKey(Handle, id, binding.Modifiers, binding.Key))
            {
                throw new InvalidOperationException(
                    $"Комбинация '{macro.Hotkey}' для макроса '{macro.Title}' занята другой программой.");
            }

            _registered[id] = macro;
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
        if (message.Msg == WmHotkey &&
            _registered.TryGetValue(message.WParam.ToInt32(), out var macro))
        {
            MacroPressed?.Invoke(macro);
        }

        base.WndProc(ref message);
    }

    public void Dispose()
    {
        UnregisterAll();
        DestroyHandle();
        GC.SuppressFinalize(this);
    }

    private static HotkeyBinding ParseHotkey(string value)
    {
        var normalized = MacroFile.NormalizeHotkey(value);
        var match = Regex.Match(
            normalized,
            "^Ctrl\\+Alt\\+([1-9])$",
            RegexOptions.CultureInvariant);

        if (!match.Success)
        {
            throw new InvalidDataException(
                $"Неподдерживаемая комбинация '{value}'. Доступны Ctrl+Alt+1 — Ctrl+Alt+9.");
        }

        var digit = int.Parse(match.Groups[1].Value);
        return new HotkeyBinding(
            ModControl | ModAlt | ModNoRepeat,
            (uint)((int)Keys.D0 + digit));
    }

    private readonly record struct HotkeyBinding(uint Modifiers, uint Key);

    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool RegisterHotKey(IntPtr windowHandle, int id, uint modifiers, uint virtualKey);

    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool UnregisterHotKey(IntPtr windowHandle, int id);
}

internal static class KeyboardInput
{
    private const uint InputKeyboard = 1;
    private const uint KeyEventKeyUp = 0x0002;
    private const uint KeyEventUnicode = 0x0004;
    private const ushort VkControl = 0x11;
    private const ushort VkReturn = 0x0D;
    private const ushort VkV = 0x56;

    internal static bool AnyModifierDown()
    {
        foreach (var virtualKey in new[] { 0x10, 0x11, 0x12, 0x5B, 0x5C })
        {
            if ((GetAsyncKeyState(virtualKey) & 0x8000) != 0)
            {
                return true;
            }
        }
        return false;
    }

    internal static bool TryTypeUnicode(string text)
    {
        if (string.IsNullOrEmpty(text))
        {
            return true;
        }

        const int maxInputsPerBatch = 256;
        var batch = new List<Input>(maxInputsPerBatch);
        var sentAny = false;

        for (var index = 0; index < text.Length; index++)
        {
            var character = text[index];
            if (character is '\r' or '\n')
            {
                if (character == '\r' && index + 1 < text.Length && text[index + 1] == '\n')
                {
                    index++;
                }

                batch.Add(Key(VkReturn, false));
                batch.Add(Key(VkReturn, true));
            }
            else
            {
                batch.Add(UnicodeKey(character, keyUp: false));
                batch.Add(UnicodeKey(character, keyUp: true));
            }

            if (batch.Count >= maxInputsPerBatch && !TrySendBatch(batch, ref sentAny))
            {
                return false;
            }
        }

        return TrySendBatch(batch, ref sentAny);
    }

    private static bool TrySendBatch(List<Input> batch, ref bool sentAny)
    {
        if (batch.Count == 0)
        {
            return true;
        }

        var inputs = batch.ToArray();
        batch.Clear();

        var sent = SendInput((uint)inputs.Length, inputs, Marshal.SizeOf<Input>());
        if (sent != (uint)inputs.Length)
        {
            if (!sentAny && sent == 0)
            {
                return false;
            }

            throw new InvalidOperationException(
                "Windows приняла только часть Unicode-ввода. Вставка остановлена, чтобы не дублировать текст через буфер обмена.");
        }

        sentAny = true;
        return true;
    }

    internal static void Paste()
    {
        var inputs = new[]
        {
            Key(VkControl, false),
            Key(VkV, false),
            Key(VkV, true),
            Key(VkControl, true)
        };

        var sent = SendInput((uint)inputs.Length, inputs, Marshal.SizeOf<Input>());
        if (sent != (uint)inputs.Length)
        {
            throw new InvalidOperationException("Windows не приняла команду вставки Ctrl+V.");
        }
    }

    private static Input UnicodeKey(char character, bool keyUp) => new()
    {
        Type = InputKeyboard,
        Union = new InputUnion
        {
            Keyboard = new KeyboardInputData
            {
                VirtualKey = 0,
                ScanCode = character,
                Flags = KeyEventUnicode | (keyUp ? KeyEventKeyUp : 0)
            }
        }
    };

    private static Input Key(ushort virtualKey, bool keyUp) => new()
    {
        Type = InputKeyboard,
        Union = new InputUnion
        {
            Keyboard = new KeyboardInputData
            {
                VirtualKey = virtualKey,
                Flags = keyUp ? KeyEventKeyUp : 0
            }
        }
    };

    [StructLayout(LayoutKind.Sequential)]
    private struct Input
    {
        public uint Type;
        public InputUnion Union;
    }

    [StructLayout(LayoutKind.Explicit)]
    private struct InputUnion
    {
        [FieldOffset(0)]
        public KeyboardInputData Keyboard;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct KeyboardInputData
    {
        public ushort VirtualKey;
        public ushort ScanCode;
        public uint Flags;
        public uint Time;
        public UIntPtr ExtraInfo;
    }

    [DllImport("user32.dll")]
    private static extern short GetAsyncKeyState(int virtualKey);

    [DllImport("user32.dll", SetLastError = true)]
    private static extern uint SendInput(uint inputCount, Input[] inputs, int inputSize);
}

internal sealed class TextMacro
{
    public string Id { get; set; } = string.Empty;
    public string Title { get; set; } = string.Empty;
    public string Hotkey { get; set; } = string.Empty;
    public string Text { get; set; } = string.Empty;

    internal TextMacro Clone() => new()
    {
        Id = Id,
        Title = Title,
        Hotkey = Hotkey,
        Text = Text
    };
}

internal static class MacroFile
{
    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        WriteIndented = true,
        Encoder = JavaScriptEncoder.UnsafeRelaxedJsonEscaping,
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase
    };

    internal static IReadOnlyList<TextMacro> LoadOrCreate(string path)
    {
        if (!File.Exists(path))
        {
            var defaults = Defaults();
            Write(path, defaults, backupExisting: false);
            return defaults;
        }

        try
        {
            var original = File.ReadAllText(path);
            using var document = JsonDocument.Parse(original);
            if (document.RootElement.ValueKind != JsonValueKind.Array)
            {
                throw new InvalidDataException("macros.json должен содержать JSON-массив.");
            }

            var macros = new List<TextMacro>();
            var index = 0;
            foreach (var element in document.RootElement.EnumerateArray())
            {
                index++;
                if (element.ValueKind != JsonValueKind.Object)
                {
                    continue;
                }

                macros.Add(new TextMacro
                {
                    Id = FirstString(element, "id") ?? $"macro-{Guid.NewGuid():N}",
                    Title = FirstString(element, "title", "name") ?? $"Макрос {index}",
                    Hotkey = FirstString(element, "hotkey", "shortcut") ?? $"Ctrl+Alt+{Math.Min(index, 9)}",
                    Text = FirstString(element, "text", "content", "template") ?? string.Empty
                });
            }

            if (macros.Count == 0)
            {
                macros = Defaults();
            }

            Normalize(macros);
            Validate(macros);

            var normalizedText = JsonSerializer.Serialize(macros, JsonOptions);
            if (!string.Equals(original.Trim(), normalizedText.Trim(), StringComparison.Ordinal))
            {
                Write(path, macros, backupExisting: true);
            }

            return macros;
        }
        catch (Exception exception)
        {
            NativeProgram.Log(exception);
            Backup(path, "corrupt");
            var defaults = Defaults();
            Write(path, defaults, backupExisting: false);
            return defaults;
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

    private static void Normalize(List<TextMacro> macros)
    {
        if (macros.Count > 9)
        {
            throw new InvalidDataException("В тестовой версии поддерживается не более девяти макросов.");
        }

        var usedIds = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        var usedHotkeys = new HashSet<string>(StringComparer.OrdinalIgnoreCase);

        for (var index = 0; index < macros.Count; index++)
        {
            var macro = macros[index];
            macro.Id = string.IsNullOrWhiteSpace(macro.Id) || !usedIds.Add(macro.Id.Trim())
                ? $"macro-{Guid.NewGuid():N}"
                : macro.Id.Trim();
            usedIds.Add(macro.Id);

            macro.Title = string.IsNullOrWhiteSpace(macro.Title)
                ? $"Макрос {index + 1}"
                : macro.Title.Trim();
            macro.Text ??= string.Empty;
            macro.Hotkey = NormalizeHotkey(macro.Hotkey);

            var validHotkey = Regex.IsMatch(
                macro.Hotkey,
                "^Ctrl\\+Alt\\+[1-9]$",
                RegexOptions.CultureInvariant);

            if (!validHotkey || !usedHotkeys.Add(macro.Hotkey))
            {
                macro.Hotkey = Enumerable.Range(1, 9)
                    .Select(number => $"Ctrl+Alt+{number}")
                    .First(candidate => usedHotkeys.Add(candidate));
            }
        }
    }

    private static void Validate(IReadOnlyCollection<TextMacro> macros)
    {
        if (macros.Count == 0)
        {
            throw new InvalidDataException("Добавьте хотя бы один макрос.");
        }

        foreach (var macro in macros)
        {
            if (string.IsNullOrWhiteSpace(macro.Text))
            {
                throw new InvalidDataException($"Текст макроса '{macro.Title}' пуст.");
            }
        }
    }

    private static void Write(string path, IReadOnlyCollection<TextMacro> macros, bool backupExisting)
    {
        Directory.CreateDirectory(Path.GetDirectoryName(path) ?? NativeProgram.BaseDirectory);
        var temporaryPath = path + ".tmp";

        try
        {
            if (backupExisting && File.Exists(path))
            {
                Backup(path, "backup");
            }

            File.WriteAllText(temporaryPath, JsonSerializer.Serialize(macros, JsonOptions));
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

    private static void Backup(string path, string label)
    {
        try
        {
            if (!File.Exists(path))
            {
                return;
            }

            var backupPath = Path.Combine(
                Path.GetDirectoryName(path) ?? NativeProgram.BaseDirectory,
                $"macros.{label}.{DateTime.Now:yyyyMMdd-HHmmss}.json");
            File.Copy(path, backupPath, false);
        }
        catch
        {
            // Recovery remains available even if a backup cannot be created.
        }
    }

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

    private static List<TextMacro> Defaults() =>
    [
        new TextMacro
        {
            Id = "macro-1",
            Title = "Проверка WHAM",
            Hotkey = "Ctrl+Alt+1",
            Text = "Добрый день! Макрос WHAM работает."
        },
        new TextMacro
        {
            Id = "macro-2",
            Title = "Заявка принята",
            Hotkey = "Ctrl+Alt+2",
            Text = "Добрый день! Заявка принята в работу."
        },
        new TextMacro
        {
            Id = "macro-3",
            Title = "Не хватает данных",
            Hotkey = "Ctrl+Alt+3",
            Text = "Добрый день! Для продолжения работы не хватает данных."
        }
    ];
}
