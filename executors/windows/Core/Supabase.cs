using System.Net;
using System.Net.Http.Headers;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;

namespace Ppomi.Executor;

/// Public service constants, identical to SupabaseAuth.swift. None is a secret: access is decided by the Google login and RLS.
public static class PpomiServer
{
    public const string SupabaseUrl = "https://nafutfqfbbmknzmyspus.supabase.co";
    public const string PublishableKey = "sb_publishable_diyhnKb7L4C1R5wt9FRoEQ_rQs8b4WX";
    public const string CallbackScheme = "ppomi";
    public const string Callback = "ppomi://auth";
}

public static class NativeHttp
{
    public static HttpClient Create(HttpMessageHandler? handler = null) => new(handler ?? new SocketsHttpHandler
    {
        AllowAutoRedirect = false, UseCookies = false, AutomaticDecompression = DecompressionMethods.None,
        ConnectTimeout = TimeSpan.FromSeconds(15), MaxResponseHeadersLength = 32
    }) { Timeout = TimeSpan.FromSeconds(120) };

    public static HttpRequestMessage JsonRequest(Uri uri, byte[] bytes)
    {
        var request = new HttpRequestMessage(HttpMethod.Post, uri) { Content = new ByteArrayContent(bytes) };
        request.Content.Headers.ContentType = new MediaTypeHeaderValue("application/json");
        request.Headers.Accept.Add(new MediaTypeWithQualityHeaderValue("application/json"));
        request.Headers.CacheControl = new CacheControlHeaderValue { NoCache = true, NoStore = true };
        return request;
    }

    public static async Task<JsonElement> ReadJson(HttpResponseMessage response, int limit, CancellationToken cancellation, bool allowArray = false)
    {
        if (response.Content.Headers.ContentLength > limit) throw new NativeFailure("response_invalid");
        await using var stream = await response.Content.ReadAsStreamAsync(cancellation);
        using var memory = new MemoryStream();
        var buffer = new byte[8192];
        while (true)
        {
            var count = await stream.ReadAsync(buffer, cancellation);
            if (count == 0) break;
            if (memory.Length + count > limit) throw new NativeFailure("response_invalid");
            memory.Write(buffer, 0, count);
        }
        try
        {
            using var document = JsonDocument.Parse(memory.ToArray(), new JsonDocumentOptions { MaxDepth = 64 });
            var kind = document.RootElement.ValueKind;
            if (kind != JsonValueKind.Object && !(allowArray && kind == JsonValueKind.Array)) throw new NativeFailure("response_invalid");
            return document.RootElement.Clone();
        }
        catch (JsonException) { throw new NativeFailure("response_invalid"); }
    }
}

/// RFC 7636 verifier/challenge pair. The verifier only ever lives in native memory until the code is exchanged.
public sealed record Pkce(string Verifier, string Challenge)
{
    public static Pkce Create()
    {
        var verifier = Base64Url(RandomNumberGenerator.GetBytes(32));
        return new Pkce(verifier, Base64Url(SHA256.HashData(Encoding.ASCII.GetBytes(verifier))));
    }
    public static string Base64Url(ReadOnlySpan<byte> data) => Convert.ToBase64String(data).TrimEnd('=').Replace('+', '-').Replace('/', '_');
}

public sealed record SupabaseTokens(string AccessToken, string RefreshToken, DateTimeOffset ExpiresAt, Guid Sub, string? DisplayName);

/// The Supabase side of the Google sign-in: the same authorize URL, callback and token grants as SupabaseAuth.swift.
public static class GoogleSignIn
{
    private static readonly Regex CodePattern = new("^[A-Za-z0-9._~-]{8,512}$", RegexOptions.CultureInvariant);

    public static Uri AuthorizeUrl(Pkce pkce) => new(PpomiServer.SupabaseUrl + "/auth/v1/authorize?provider=google&redirect_to=" +
        Uri.EscapeDataString(PpomiServer.Callback) + "&code_challenge=" + pkce.Challenge + "&code_challenge_method=s256");

    /// The browser hands back ppomi://auth?code=… . Any other scheme/host, or a missing/odd code, is not a login result.
    public static string? CodeFromCallback(string callback)
    {
        if (callback.Length > 4096 || callback.Any(char.IsWhiteSpace) || !Uri.TryCreate(callback, UriKind.Absolute, out var uri)) return null;
        if (uri.Scheme != PpomiServer.CallbackScheme || uri.Host != "auth" || uri.UserInfo != "") return null;
        string? code = null;
        foreach (var pair in uri.Query.TrimStart('?').Split('&', StringSplitOptions.RemoveEmptyEntries))
        {
            var separator = pair.IndexOf('=');
            if (separator <= 0) continue;
            var key = Uri.UnescapeDataString(pair[..separator]);
            if (key == "error" || key == "error_description") return null;
            if (key == "code") { if (code != null) return null; code = Uri.UnescapeDataString(pair[(separator + 1)..]); }
        }
        return code != null && CodePattern.IsMatch(code) ? code : null;
    }

    /// Token endpoint body → tokens. Only sub and a display name are read from the JWT (unverified; the server verifies the token).
    public static SupabaseTokens ParseTokens(JsonElement json)
    {
        var access = JsonArgs.String(json, "access_token", 16384);
        var refresh = JsonArgs.String(json, "refresh_token", 4096);
        if (access.Length < 16 || access.Any(char.IsWhiteSpace) || refresh.Any(char.IsWhiteSpace) ||
            !json.TryGetProperty("expires_in", out var expiry) || !expiry.TryGetInt32(out var seconds) || seconds <= 0)
            throw new NativeFailure("server_auth");
        var claims = Claims(access);
        if (!Guid.TryParse(claims.TryGetProperty("sub", out var sub) && sub.ValueKind == JsonValueKind.String ? sub.GetString() : null, out var subject))
            throw new NativeFailure("server_auth");
        string? name = null;
        if (claims.TryGetProperty("user_metadata", out var meta) && meta.ValueKind == JsonValueKind.Object)
        {
            foreach (var key in new[] { "full_name", "name" })
                if (meta.TryGetProperty(key, out var value) && value.ValueKind == JsonValueKind.String && value.GetString() is { Length: > 0 and <= 120 } text) { name = text; break; }
        }
        return new SupabaseTokens(access, refresh, DateTimeOffset.UtcNow.AddSeconds(Math.Min(seconds, 86400)), subject, name);
    }

    private static JsonElement Claims(string jwt)
    {
        var parts = jwt.Split('.');
        if (parts.Length != 3) throw new NativeFailure("server_auth");
        try
        {
            var payload = parts[1].Replace('-', '+').Replace('_', '/');
            payload = payload.PadRight((payload.Length + 3) / 4 * 4, '=');
            using var document = JsonDocument.Parse(Convert.FromBase64String(payload), new JsonDocumentOptions { MaxDepth = 16 });
            if (document.RootElement.ValueKind != JsonValueKind.Object) throw new NativeFailure("server_auth");
            return document.RootElement.Clone();
        }
        catch (NativeFailure) { throw; }
        catch { throw new NativeFailure("server_auth"); }
    }
}

/// A non-2xx answer from Supabase. Callers map it to a bridge code; bodies are never surfaced.
public sealed class ServerRefusal(int status) : Exception("server_refusal")
{
    public int Status { get; } = status;
}

/// Supabase Auth (PKCE exchange, refresh) and the few RPCs the Windows device needs. Tokens stay in native memory.
public sealed class SupabaseClient(HttpClient client)
{
    private static readonly HashSet<string> Rpcs = ["ppomi_register_device", "ppomi_context", "ppomi_key_get"];

    public Task<SupabaseTokens> Exchange(string code, string verifier, CancellationToken cancellation) =>
        Token("pkce", new { auth_code = code, code_verifier = verifier }, cancellation);

    public Task<SupabaseTokens> Refresh(string refreshToken, CancellationToken cancellation) =>
        Token("refresh_token", new { refresh_token = refreshToken }, cancellation);

    private async Task<SupabaseTokens> Token(string grant, object body, CancellationToken cancellation)
    {
        using var request = NativeHttp.JsonRequest(new Uri(PpomiServer.SupabaseUrl + "/auth/v1/token?grant_type=" + grant), JsonSerializer.SerializeToUtf8Bytes(body));
        request.Headers.Add("apikey", PpomiServer.PublishableKey);
        using var response = await Send(request, cancellation);
        if (response.StatusCode != HttpStatusCode.OK) throw new ServerRefusal((int)response.StatusCode);
        return GoogleSignIn.ParseTokens(await NativeHttp.ReadJson(response, 65536, cancellation));
    }

    /// Authenticated RPC with the device header, exactly what the Mac and iPad send.
    public async Task<JsonElement> Rpc(string name, object arguments, string accessToken, Guid deviceId, CancellationToken cancellation)
    {
        if (!Rpcs.Contains(name)) throw new NativeFailure("invalid_request");
        using var request = NativeHttp.JsonRequest(new Uri(PpomiServer.SupabaseUrl + "/rest/v1/rpc/" + name), JsonSerializer.SerializeToUtf8Bytes(arguments));
        request.Headers.Add("apikey", PpomiServer.PublishableKey);
        request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", accessToken);
        request.Headers.Add("X-Ppomi-Device", deviceId.ToString("D"));
        using var response = await Send(request, cancellation);
        if (!response.IsSuccessStatusCode) throw new ServerRefusal((int)response.StatusCode);
        return await NativeHttp.ReadJson(response, 65536, cancellation);
    }

    private async Task<HttpResponseMessage> Send(HttpRequestMessage request, CancellationToken cancellation)
    {
        try { return await client.SendAsync(request, HttpCompletionOption.ResponseHeadersRead, cancellation); }
        catch (HttpRequestException) { throw new NativeFailure("server_unavailable"); }
        catch (OperationCanceledException) when (!cancellation.IsCancellationRequested) { throw new NativeFailure("server_unavailable"); }
    }
}
