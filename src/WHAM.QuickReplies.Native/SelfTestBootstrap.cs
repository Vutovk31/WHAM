using System.Runtime.CompilerServices;
using System.Text.Json;
using System.Text.RegularExpressions;

namespace WHAM.QuickReplies.Native;

internal static class SelfTestBootstrap
{
    private const string SelfTestArgument = "--self-test";

    [ModuleInitializer]
    internal static void Initialize()
    {
        if (!Environment.GetCommandLineArgs().Skip(1).Any(argument =>
                string.Equals(argument, SelfTestArgument, StringComparison.OrdinalIgnoreCase)))
        {
            return;
        }

        var logPath = Path.Combine(AppContext.BaseDirectory, "WHAM-self-test.log");

        try
        {
            var macroCount = ValidatePublishedPackage();
            File.WriteAllText(
                logPath,
                $"PASS | {NativeProgram.ProductName} {NativeProgram.Version} | {macroCount} macros | native package self-test");
            Environment.Exit(0);
        }
        catch (Exception exception)
        {
            try
            {
                File.WriteAllText(
                    logPath,
                    $"FAIL | {NativeProgram.ProductName} {NativeProgram.Version} | {exception.GetType().Name}: {exception.Message}");
            }
            catch
            {
                // Preserve the original self-test failure even if the log cannot be written.
            }

            Environment.Exit(1);
        }
    }

    private static int ValidatePublishedPackage()
    {
        var baseDirectory = AppContext.BaseDirectory;
        var versionPath = Path.Combine(baseDirectory, "VERSION.txt");
        var macrosPath = Path.Combine(baseDirectory, "macros.json");
        var readmePath = Path.Combine(baseDirectory, "README-FIRST.txt");

        RequireFile(versionPath);
        RequireFile(macrosPath);
        RequireFile(readmePath);

        var version = File.ReadAllText(versionPath).Trim();
        if (!string.Equals(version, NativeProgram.Version, StringComparison.Ordinal))
        {
            throw new InvalidDataException(
                $"VERSION.txt mismatch: expected '{NativeProgram.Version}', found '{version}'.");
        }

        using var document = JsonDocument.Parse(File.ReadAllText(macrosPath));
        if (document.RootElement.ValueKind != JsonValueKind.Array)
        {
            throw new InvalidDataException("macros.json must contain a JSON array.");
        }

        var ids = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        var hotkeys = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        var count = 0;

        foreach (var macro in document.RootElement.EnumerateArray())
        {
            count++;
            if (macro.ValueKind != JsonValueKind.Object)
            {
                throw new InvalidDataException($"Macro #{count} is not a JSON object.");
            }

            var id = RequireString(macro, "id", count);
            _ = RequireString(macro, "title", count);
            var hotkey = RequireString(macro, "hotkey", count);
            var text = RequireString(macro, "text", count);

            if (!ids.Add(id))
            {
                throw new InvalidDataException($"Duplicate macro id '{id}'.");
            }

            if (!hotkeys.Add(hotkey))
            {
                throw new InvalidDataException($"Duplicate hotkey '{hotkey}'.");
            }

            if (!Regex.IsMatch(hotkey, "^Ctrl\\+Alt\\+[1-9]$", RegexOptions.CultureInvariant))
            {
                throw new InvalidDataException($"Unsupported hotkey '{hotkey}'.");
            }

            if (string.IsNullOrWhiteSpace(text))
            {
                throw new InvalidDataException($"Macro '{id}' has empty text.");
            }
        }

        if (count is < 1 or > 9)
        {
            throw new InvalidDataException($"Expected 1-9 macros, found {count}.");
        }

        return count;
    }

    private static void RequireFile(string path)
    {
        if (!File.Exists(path))
        {
            throw new FileNotFoundException($"Required package file is missing: {Path.GetFileName(path)}", path);
        }
    }

    private static string RequireString(JsonElement macro, string propertyName, int index)
    {
        if (!macro.TryGetProperty(propertyName, out var property) ||
            property.ValueKind != JsonValueKind.String ||
            string.IsNullOrWhiteSpace(property.GetString()))
        {
            throw new InvalidDataException($"Macro #{index} is missing non-empty '{propertyName}'.");
        }

        return property.GetString()!;
    }
}
