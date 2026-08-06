using System.Runtime.CompilerServices;
using System.Text.Json;
using System.Text.RegularExpressions;

namespace WHAM.QuickReplies.Native;

internal static class NativeSelfTestBootstrap
{
    private const string ProductName = "WHAM Quick Replies";
    private const string Version = "0.10.0-native-test1";

    [ModuleInitializer]
    internal static void Initialize()
    {
        if (!Environment.GetCommandLineArgs()
                .Skip(1)
                .Any(argument => string.Equals(argument, "--self-test", StringComparison.OrdinalIgnoreCase)))
        {
            return;
        }

        var baseDirectory = AppContext.BaseDirectory;
        var logPath = Path.Combine(baseDirectory, "WHAM-self-test.log");

        try
        {
            var versionPath = Path.Combine(baseDirectory, "VERSION.txt");
            var macrosPath = Path.Combine(baseDirectory, "macros.json");

            if (!File.Exists(versionPath))
            {
                throw new FileNotFoundException("VERSION.txt is missing from the portable package.", versionPath);
            }

            if (!File.Exists(macrosPath))
            {
                throw new FileNotFoundException("macros.json is missing from the portable package.", macrosPath);
            }

            var packageVersion = File.ReadAllText(versionPath).Trim();
            if (!string.Equals(packageVersion, Version, StringComparison.Ordinal))
            {
                throw new InvalidDataException(
                    $"VERSION.txt mismatch: expected '{Version}', found '{packageVersion}'.");
            }

            using var document = JsonDocument.Parse(File.ReadAllText(macrosPath));
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
                    throw new InvalidDataException($"Macro #{count} must be a JSON object.");
                }

                var id = RequiredString(element, "id", count);
                _ = RequiredString(element, "title", count);
                var hotkey = RequiredString(element, "hotkey", count);
                _ = RequiredString(element, "text", count);

                if (!ids.Add(id))
                {
                    throw new InvalidDataException($"Duplicate macro id: '{id}'.");
                }

                if (!Regex.IsMatch(
                        hotkey,
                        "^Ctrl\\+Alt\\+[1-9]$",
                        RegexOptions.CultureInvariant | RegexOptions.IgnoreCase))
                {
                    throw new InvalidDataException(
                        $"Unsupported hotkey '{hotkey}'. Expected Ctrl+Alt+1 through Ctrl+Alt+9.");
                }

                if (!hotkeys.Add(hotkey))
                {
                    throw new InvalidDataException($"Duplicate hotkey: '{hotkey}'.");
                }
            }

            if (count is < 1 or > 9)
            {
                throw new InvalidDataException($"Expected 1 to 9 macros, found {count}.");
            }

            File.WriteAllText(
                logPath,
                $"PASS | {ProductName} {Version} | macros={count} | package files valid{Environment.NewLine}");
            Environment.ExitCode = 0;
        }
        catch (Exception exception)
        {
            try
            {
                File.WriteAllText(
                    logPath,
                    $"FAIL | {ProductName} {Version} | {exception.GetType().Name}: {exception.Message}{Environment.NewLine}");
            }
            catch
            {
                // Preserve the self-test failure even if the diagnostic log cannot be written.
            }

            Environment.ExitCode = 1;
        }

        Environment.Exit(Environment.ExitCode);
    }

    private static string RequiredString(JsonElement element, string propertyName, int macroNumber)
    {
        if (!element.TryGetProperty(propertyName, out var value) ||
            value.ValueKind != JsonValueKind.String ||
            string.IsNullOrWhiteSpace(value.GetString()))
        {
            throw new InvalidDataException(
                $"Macro #{macroNumber} has no non-empty '{propertyName}' string.");
        }

        return value.GetString()!;
    }
}
