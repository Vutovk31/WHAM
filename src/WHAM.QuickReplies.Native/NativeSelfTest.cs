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

        var packagedMacroText = File.ReadAllText(macroPath);
        using var document = JsonDocument.Parse(packagedMacroText);
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

        VerifyRuntimeLoadDoesNotRewriteValidMacros(packagedMacroText, count);
        VerifyMalformedJsonRecoveryPreservesEvidence();
    }

    private static void VerifyRuntimeLoadDoesNotRewriteValidMacros(string packagedMacroText, int expectedCount)
    {
        var testDirectory = Path.Combine(
            Path.GetTempPath(),
            $"wham-self-test-{Guid.NewGuid():N}");
        Directory.CreateDirectory(testDirectory);

        try
        {
            var testMacroPath = Path.Combine(testDirectory, "macros.json");
            File.WriteAllText(testMacroPath, packagedMacroText);

            var loaded = MacroFile.LoadOrCreate(testMacroPath);
            if (loaded.Count != expectedCount)
            {
                throw new InvalidDataException(
                    $"Runtime macro load changed macro count: expected {expectedCount}, found {loaded.Count}.");
            }

            var afterLoad = File.ReadAllText(testMacroPath);
            if (!string.Equals(packagedMacroText, afterLoad, StringComparison.Ordinal))
            {
                throw new InvalidDataException(
                    "Runtime macro load rewrote an already valid macros.json file.");
            }
        }
        finally
        {
            try
            {
                Directory.Delete(testDirectory, recursive: true);
            }
            catch
            {
                // Temporary self-test cleanup must not hide the validation result.
            }
        }
    }

    private static void VerifyMalformedJsonRecoveryPreservesEvidence()
    {
        var testDirectory = Path.Combine(
            Path.GetTempPath(),
            $"wham-self-test-corrupt-{Guid.NewGuid():N}");
        Directory.CreateDirectory(testDirectory);

        try
        {
            const string malformedJson = "[{\"id\":\"broken\",\"title\":\"Broken\"";
            var testMacroPath = Path.Combine(testDirectory, "macros.json");
            File.WriteAllText(testMacroPath, malformedJson);

            var loaded = MacroFile.LoadOrCreate(testMacroPath);
            if (loaded.Count == 0)
            {
                throw new InvalidDataException(
                    "Malformed macros.json recovery returned no default macros.");
            }

            var backups = Directory.GetFiles(testDirectory, "macros.corrupt.*.json");
            if (backups.Length != 1)
            {
                throw new InvalidDataException(
                    $"Malformed macros.json recovery must create exactly one corrupt backup, found {backups.Length}.");
            }

            var preserved = File.ReadAllText(backups[0]);
            if (!string.Equals(preserved, malformedJson, StringComparison.Ordinal))
            {
                throw new InvalidDataException(
                    "Malformed macros.json backup did not preserve the original file exactly.");
            }

            using var recoveredDocument = JsonDocument.Parse(File.ReadAllText(testMacroPath));
            if (recoveredDocument.RootElement.ValueKind != JsonValueKind.Array)
            {
                throw new InvalidDataException(
                    "Malformed macros.json recovery did not produce a valid JSON array.");
            }
        }
        finally
        {
            try
            {
                Directory.Delete(testDirectory, recursive: true);
            }
            catch
            {
                // Temporary self-test cleanup must not hide the validation result.
            }
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
