using System.Net;
using System.Net.Http.Headers;
using System.Text.Json;

namespace Ppomi.Executor;

// Long-lived credentials and Supabase bearer tokens never become protocol results.
// Two credentials exist: the Google session of this device (product path, sends X-Ppomi-Device like the Mac and iPad) and,
// only with the developer import flag, the legacy email/password device account. The Google session always wins.
public sealed class ServerProxy : IDisposable
{
    private readonly HttpClient client;
    private readonly bool ownsClient;
    private readonly GoogleAccount? account;
    private readonly SemaphoreSlim authGate = new(1, 1);
    private readonly object configurationGate = new();
    private DeviceConfiguration? configuration;
    private string? accessToken;
    private DateTimeOffset expiresAt;

    public ServerProxy(DeviceConfiguration? configuration, HttpMessageHandler? testHandler = null, GoogleAccount? account = null, HttpClient? sharedClient = null)
    {
        this.configuration = configuration;
        this.account = account;
        ownsClient = sharedClient == null;
        client = sharedClient ?? NativeHttp.Create(testHandler);
    }

    /// Some credential exists. Whether the device may actually converse is `Connected`.
    public bool Configured => account?.SignedIn == true || LegacyConfigured;
    public bool LegacyConfigured { get { lock (configurationGate) return configuration != null; } }
    /// Google session: signed in and registered (MZZ-27). Legacy import: the imported device account is present.
    public bool Connected => account?.SignedIn == true ? account.Snapshot.Configured : LegacyConfigured;

    public void Configure(DeviceConfiguration value)
    {
        lock (configurationGate) { configuration = value; accessToken = null; expiresAt = default; }
    }

    public async Task<JsonElement> Request(string endpoint, string route, JsonElement body, NativeSession.Lease lease)
    {
        lease.Check();
        var uri = NativePolicy.RequestUri(endpoint, route);
        if (body.ValueKind != JsonValueKind.Object) throw new NativeFailure("invalid_request");
        var bytes = JsonSerializer.SerializeToUtf8Bytes(body);
        if (bytes.Length > 1024 * 1024) throw new NativeFailure("invalid_request");
        try
        {
            var (token, deviceId) = await Authenticate(lease.Token);
            lease.Check();
            using var request = NativeHttp.JsonRequest(uri, bytes);
            request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", token);
            if (deviceId is { } device) request.Headers.Add("X-Ppomi-Device", device.ToString("D"));
            using var response = await client.SendAsync(request, HttpCompletionOption.ResponseHeadersRead, lease.Token);
            if (response.StatusCode == HttpStatusCode.Unauthorized)
            {
                lock (configurationGate) accessToken = null;
                throw new NativeFailure("server_auth");
            }
            if (!response.IsSuccessStatusCode) throw new NativeFailure("server_rejected");
            var result = await NativeHttp.ReadJson(response, 2_000_000, lease.Token);
            lease.Check();
            return result;
        }
        catch (NativeFailure) { throw; }
        catch (OperationCanceledException) { lease.Check(); throw new NativeFailure("server_unavailable"); }
        catch (HttpRequestException) { throw new NativeFailure("server_unavailable"); }
    }

    private async Task<(string Token, Guid? DeviceId)> Authenticate(CancellationToken cancellation)
    {
        if (account?.SignedIn == true)
        {
            return (await account.AccessToken(cancellation), account.DeviceId);
        }
        await authGate.WaitAsync(cancellation);
        try
        {
            DeviceConfiguration config;
            lock (configurationGate)
            {
                config = configuration ?? throw new NativeFailure("server_unconfigured");
                if (accessToken != null && expiresAt > DateTimeOffset.UtcNow) return (accessToken, null);
            }
            using var auth = NativeHttp.JsonRequest(new Uri(config.Url + "/auth/v1/token?grant_type=password"),
                JsonSerializer.SerializeToUtf8Bytes(new { email = config.Email, password = config.Password }));
            auth.Headers.Add("apikey", config.PublishableKey);
            using var response = await client.SendAsync(auth, HttpCompletionOption.ResponseHeadersRead, cancellation);
            if (response.StatusCode != HttpStatusCode.OK) throw new NativeFailure("server_auth");
            var json = await NativeHttp.ReadJson(response, 65536, cancellation);
            var token = JsonArgs.String(json, "access_token", 16384);
            if (token.Length < 16 || token.Any(char.IsWhiteSpace) ||
                !json.TryGetProperty("expires_in", out var expiry) || !expiry.TryGetInt32(out var seconds) || seconds <= 0)
                throw new NativeFailure("server_auth");

            using var context = NativeHttp.JsonRequest(new Uri(config.Url + "/rest/v1/rpc/ppomi_context"), "{}"u8.ToArray());
            context.Headers.Add("apikey", config.PublishableKey);
            context.Headers.Authorization = new AuthenticationHeaderValue("Bearer", token);
            using var contextResponse = await client.SendAsync(context, HttpCompletionOption.ResponseHeadersRead, cancellation);
            if (contextResponse.StatusCode != HttpStatusCode.OK) throw new NativeFailure("server_auth");
            var contextJson = await NativeHttp.ReadJson(contextResponse, 65536, cancellation);
            var device = JsonArgs.Object(contextJson, "device");
            var workspace = JsonArgs.Object(contextJson, "workspace");
            if (!Guid.TryParse(JsonArgs.String(device, "id", 36), out var deviceId) || deviceId != config.DeviceId ||
                !Guid.TryParse(JsonArgs.String(workspace, "id", 36), out _) ||
                !contextJson.TryGetProperty("devices", out var devices) || devices.ValueKind != JsonValueKind.Array)
                throw new NativeFailure("server_auth");
            lock (configurationGate)
            {
                cancellation.ThrowIfCancellationRequested();
                if (!ReferenceEquals(configuration, config)) throw new NativeFailure("session_ended");
                accessToken = token;
                expiresAt = DateTimeOffset.UtcNow.AddSeconds(Math.Max(0, Math.Min(seconds, 86400) - 30));
            }
            return (token, null);
        }
        finally { authGate.Release(); }
    }

    public void Dispose() { if (ownsClient) client.Dispose(); authGate.Dispose(); }
}
