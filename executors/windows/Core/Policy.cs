using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;

namespace Ppomi.Executor;

public sealed class NativeFailure(string code) : Exception(code)
{
    public string Code { get; } = code;
}

public static class JsonArgs
{
    public static JsonElement Object(JsonElement parent, string key)
    {
        if (!parent.TryGetProperty(key, out var value) || value.ValueKind != JsonValueKind.Object)
            throw new NativeFailure("invalid_request");
        return value;
    }

    public static string String(JsonElement parent, string key, int max, bool empty = false)
    {
        if (!parent.TryGetProperty(key, out var value) || value.ValueKind != JsonValueKind.String)
            throw new NativeFailure("invalid_request");
        var result = value.GetString()!;
        if (result.Length > max || (!empty && result.Length == 0) || result.Contains('\0'))
            throw new NativeFailure("invalid_request");
        return result;
    }
}

public static class NativePolicy
{
    // Matches the app's shared service constant. Endpoint selection is not an onboarding step.
    public const string DefaultAgentEndpoint = "https://ppomi-agent.vercel.app";
    public const int MaxFileBytes = 128 * 1024;
    public static readonly UTF8Encoding Utf8 = new(false, true);
    private static readonly HashSet<string> Routes = ["/v1/session", "/v1/responses", "/v1/memories/list", "/v1/memories/save", "/v1/memories/delete"];

    // Kept for CLI/development compatibility. Missing/empty settings use the standard service.
    public static string ConfiguredEndpoint(string? value) =>
        Endpoint(string.IsNullOrEmpty(value) ? DefaultAgentEndpoint : value).AbsoluteUri.TrimEnd('/');

    public static Uri Endpoint(string value)
    {
        // Check raw input before System.Uri normalizes dot segments and escaped separators.
        if (value.Length is 0 or > 2048 || value.Any(char.IsWhiteSpace) || value.Contains('%') ||
            value.Contains('\\') || value.Contains("..", StringComparison.Ordinal) ||
            !Uri.TryCreate(value, UriKind.Absolute, out var uri) || uri.Scheme != "https" ||
            string.IsNullOrEmpty(uri.Host) || uri.UserInfo != "" || uri.Query != "" || uri.Fragment != "")
            throw new NativeFailure("invalid_request");
        return new Uri(uri.AbsoluteUri.TrimEnd('/') + "/");
    }

    public static Uri RequestUri(string endpoint, string route)
    {
        if (!Routes.Contains(route)) throw new NativeFailure("invalid_request");
        return new Uri(Endpoint(endpoint), route.TrimStart('/'));
    }

    public static string[] WorkspaceParts(string path, bool allowRoot)
    {
        if (path == "" && allowRoot) return [];
        if (Utf8.GetByteCount(path) > 1024 || path.Contains('\\') || path.Contains(':') || path.Contains('\0'))
            throw new NativeFailure("invalid_request");
        var parts = path.Split('/');
        if (parts.Length > 16 || parts.Any(p => p.Length == 0 || p is "." or ".." ||
                p.EndsWith('.') || p.EndsWith(' ') || p.Any(c => c < 32 || "<>\"|?*".Contains(c)) ||
                p.StartsWith(".ppomi-write-", StringComparison.OrdinalIgnoreCase) ||
                Utf8.GetByteCount(p) > 255 || IsReservedWindowsName(p)))
            throw new NativeFailure("invalid_request");
        return parts;
    }

    private static bool IsReservedWindowsName(string part) => Regex.IsMatch(part.Split('.')[0],
        "^(CON|PRN|AUX|NUL|COM[0-9¹²³]|LPT[0-9¹²³]|CONIN\\$|CONOUT\\$)$", RegexOptions.IgnoreCase | RegexOptions.CultureInvariant);

    // This is a conservative additional deny rule, not a semantic transaction classifier.
    public static bool ProtectedLabel(string value) => Regex.IsMatch(value,
        "pay|purchase|checkout|transfer|send|submit|delete|remove|confirm|approve|allow|permission|password|sign.?in|log.?in|install|uninstall|run|execute|terminal|command|결제|구매|송금|이체|전송|제출|삭제|제거|확인|승인|허용|권한|비밀번호|로그인|설치|실행|명령",
        RegexOptions.IgnoreCase | RegexOptions.CultureInvariant);

    public static bool IsCommandHost(string fileName) => new HashSet<string>(StringComparer.OrdinalIgnoreCase)
    {
        "cmd.exe", "powershell.exe", "pwsh.exe", "WindowsTerminal.exe", "wt.exe", "wsl.exe", "bash.exe",
        "regedit.exe", "mmc.exe", "taskmgr.exe", "explorer.exe", "SystemSettings.exe", "control.exe",
        "rundll32.exe", "mshta.exe", "wscript.exe", "cscript.exe", "conhost.exe", "OpenConsole.exe"
    }.Contains(fileName);
}

public sealed record DeviceConfiguration(string Url, string PublishableKey, string Email, string Password, Guid DeviceId)
{
    public static DeviceConfiguration Decode(ReadOnlyMemory<byte> bytes)
    {
        if (bytes.Length > 16384) throw new NativeFailure("invalid_request");
        try
        {
            using var document = JsonDocument.Parse(bytes, new JsonDocumentOptions { MaxDepth = 8 });
            var json = document.RootElement;
            var url = JsonArgs.String(json, "url", 2048);
            var key = JsonArgs.String(json, "publishableKey", 4096);
            var email = JsonArgs.String(json, "email", 254);
            var password = JsonArgs.String(json, "password", 256);
            if (!Regex.IsMatch(url, "^https://[a-z0-9]{1,63}\\.supabase\\.co/?$", RegexOptions.CultureInvariant) ||
                !Uri.TryCreate(url, UriKind.Absolute, out var uri) || uri.Scheme != "https" ||
                !Regex.IsMatch(uri.Host, "^[a-z0-9]{1,63}\\.supabase\\.co$", RegexOptions.CultureInvariant) ||
                !uri.IsDefaultPort || uri.UserInfo != "" || uri.Query != "" || uri.Fragment != "" ||
                (uri.AbsolutePath != "/" && uri.AbsolutePath != "") || url.Contains('%') || url.Any(char.IsWhiteSpace) ||
                !ValidKey(key) || !email.Contains('@') || email.Any(char.IsWhiteSpace) || password.Length < 12 ||
                !Guid.TryParse(JsonArgs.String(json, "deviceId", 36), out var device))
                throw new NativeFailure("invalid_request");
            return new(uri.GetLeftPart(UriPartial.Authority), key, email, password, device);
        }
        catch (NativeFailure) { throw; }
        catch { throw new NativeFailure("invalid_request"); }
    }

    private static bool ValidKey(string key)
    {
        if (Regex.IsMatch(key, "^sb_publishable_[A-Za-z0-9_-]{16,256}$", RegexOptions.CultureInvariant)) return true;
        var parts = key.Split('.');
        if (parts.Length != 3 || parts.Any(p => !Regex.IsMatch(p, "^[A-Za-z0-9_-]+$", RegexOptions.CultureInvariant))) return false;
        try
        {
            var payload = parts[1].Replace('-', '+').Replace('_', '/');
            payload = payload.PadRight((payload.Length + 3) / 4 * 4, '=');
            using var doc = JsonDocument.Parse(Convert.FromBase64String(payload));
            return doc.RootElement.TryGetProperty("role", out var role) && role.GetString() == "anon";
        }
        catch { return false; }
    }
}
