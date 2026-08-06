using System.Runtime.CompilerServices;
using System.Text.Json;
using System.Text.RegularExpressions;

namespace WHAM.QuickReplies.Native;

internal static class NativeSelfTest
{
    private const string SelfTestArgument = "--self-test";

    [ModuleInitializer]
    internal static void Initialize()
    {
        if (!Environment.GetCommandLineArgs().Any(
                argument => string.Equals(argument, SelfTestArgument, StringComparison.OrdinalIgnoreCase)))
        {
            return;
        }

        var baseDirectory = AppContext.BaseDirectory;
        var logPath = Path.Combine(baseDirectory, "WHAM-self-test.log");

        try
        {
            Run(baseDirectory);
            File.WriteAllText(
                logPath,
                $"PASS | WHAM Quick Replies {NativeProgram.Version} | {DateTime.UtcNow:O}{Environment.NewLine}");
            Environment.Exit(0);
        }
        catch (Exception exception)
        {
            File.WriteAllText(
                logPath,
                $"FAIL | WHAM Quick Replies {NativeProgram.Version} | {DateTime.UtcNow:O}{Environment.NewLine}{exception}{Environment.NewLine}");
            Environment.Exit(1);
        }
    }

    private static void Run(string baseDirectory)
    {
        var versionPath = Path.Combine(baseDirectory, "VERSION.txt");
        var macroPath = Path.Combine(baseDirectory, "macros.json");

        RequireFile(versionPath);
        RequireFile(macroPath);

        var packagedVersion = File.ReadAllText(versionPath).Trim();
        if (!string.Equals(packagedVersion, NativeProgram.Version, StringComparison.Ordinal))
        {
            throw new InvalidDataException(
                $"VERSION.txt mismatch: expected '{NativeProgram.Version}', found '{packagedVersion}'.");
        }

        using var document = JsonDocument.Parse(File.ReadAllText(macroPath));
        if (document.RootElement.ValueKind != JsonValueKind.Array)
        {
            throw new InvalidDataException("macros.json must contain a JSON array.");
        }

        var ids = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        var hotkeys = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        var count = 0;

        foreach (var element in document.RootElement.EnumerateArray())
        {
            count++;
            if (element.ValueKind != JsonValueKind.Object)
            {
                throw new InvalidDataException($"Macro #{count} is not a JSON object.");
            }

            var id = RequiredString(element, "id", count);
            var title = RequiredString(element, "title", count);
            var hotkey = RequiredString(element, "hotkey", count);
            var text = RequiredString(element, "text", count);

            if (!ids.Add(id))
            {
                throw new InvalidDataException($"Duplicate macro id: '{id}'.");
            }

            if (!Regex.IsMatch(hotkey, "^Ctrl\\+Alt\\+[1-9]$", RegexOptions.CultureInvariant))
            {
                throw new InvalidDataException(
                    $"Macro '{title}' has unsupported hotkey '{hotkey}'.");
            }

            if (!hotkeys.Add(hotkey))
            {
                throw new InvalidDataException($"Duplicate hotkey: '{hotkey}'.");
            }

            if (string.IsNullOrWhiteSpace(text))
            {
                throw new InvalidDataException($"Macro '{title}' has empty text.");
            }
        }

        if (count is < 1 or > 9)
        {
            throw new InvalidDataException(
                $"Expected between 1 and 9 macros, found {count}.");
        }
    }

    private static void RequireFile(string path)
    {
        if (!File.Exists(path))
        {
            throw new FileNotFoundException("Required portable package file is missing.", path);
        }
    }

    private static string RequiredString(JsonElement element, string propertyName, int index)
    {
        if (!element.TryGetProperty(propertyName, out var value) ||
            value.ValueKind != JsonValueKind.String ||
            string.IsNullOrWhiteSpace(value.GetString()))
        {
            throw new InvalidDataException(
                $"Macro #{index} has no non-empty string property '{propertyName}'.");
        }

        return value.GetString()!;
    }
}
