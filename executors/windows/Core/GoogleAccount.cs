using System.Text.Json;

namespace Ppomi.Executor;

/// The Google session of this Windows device: Supabase tokens plus what the server last said about the device.
/// `Registered` = ppomi_register_device succeeded once for this installation; `Approved` = the owner approved it on the Mac.
public sealed record GoogleSession(string AccessToken, string RefreshToken, DateTimeOffset ExpiresAt, Guid Sub, string? DisplayName,
    bool Registered, bool Approved, Guid? WorkspaceId)
{
    public byte[] Encode() => JsonSerializer.SerializeToUtf8Bytes(new
    {
        accessToken = AccessToken, refreshToken = RefreshToken, expiresAt = ExpiresAt.ToUnixTimeSeconds(), sub = Sub,
        displayName = DisplayName, registered = Registered, approved = Approved, workspaceId = WorkspaceId
    });

    public static GoogleSession? Decode(ReadOnlyMemory<byte> bytes)
    {
        if (bytes.Length > 65536) return null;
        try
        {
            using var document = JsonDocument.Parse(bytes, new JsonDocumentOptions { MaxDepth = 8 });
            var json = document.RootElement;
            if (!json.TryGetProperty("expiresAt", out var expires) || !expires.TryGetInt64(out var unix) ||
                !Guid.TryParse(JsonArgs.String(json, "sub", 36), out var sub)) return null;
            Guid? workspace = json.TryGetProperty("workspaceId", out var ws) && ws.ValueKind == JsonValueKind.String && Guid.TryParse(ws.GetString(), out var id) ? id : null;
            var name = json.TryGetProperty("displayName", out var display) && display.ValueKind == JsonValueKind.String ? display.GetString() : null;
            return new GoogleSession(JsonArgs.String(json, "accessToken", 16384), JsonArgs.String(json, "refreshToken", 4096),
                DateTimeOffset.FromUnixTimeSeconds(unix), sub, name is { Length: > 0 and <= 120 } ? name : null,
                Flag(json, "registered"), Flag(json, "approved"), workspace);
        }
        catch { return null; }
    }

    private static bool Flag(JsonElement json, string key) => json.TryGetProperty(key, out var value) && value.ValueKind == JsonValueKind.True;
}

/// Per-installation state. Windows implements it with DPAPI files; tests with memory. Nothing here reaches JavaScript.
public interface IAccountStore
{
    /// Stable device ID of this installation. Not a secret; it becomes the X-Ppomi-Device header and the server row.
    Guid DeviceId { get; }
    /// 32-byte X25519 scalar, created on first use. Only its public key leaves the device.
    byte[] DevicePrivateKey();
    GoogleSession? LoadSession();
    void SaveSession(GoogleSession session);
    void DeleteSession();
    RecordKey? LoadRecordKey();
    void SaveRecordKey(RecordKey key);
    void DeleteRecordKey();
}

/// Presentation state for the shell. No token, email, or key ever appears here.
public sealed record AccountSnapshot(bool SignedIn, bool Registered, bool Approved, bool RecordKey, string? DisplayName)
{
    /// The device may hold a conversation only once the owner approved it. Sign-in alone is not a connection.
    public bool Configured => SignedIn && Registered && Approved;
    public bool PendingApproval => SignedIn && Registered && !Approved;
    public object Json => new { signedIn = SignedIn, registered = Registered, approved = Approved, pendingApproval = PendingApproval, recordKey = RecordKey, displayName = DisplayName };
}

/// Sign-in, device registration, approval polling and the wrapped record key. One instance per executor process.
public sealed class GoogleAccount
{
    private readonly IAccountStore store;
    private readonly SupabaseClient supabase;
    private readonly string deviceLabel;
    private readonly SemaphoreSlim gate = new(1, 1);
    private readonly object snapshotGate = new();
    private GoogleSession? session;
    private RecordKey? recordKey;
    private (Pkce Pkce, DateTimeOffset Expires)? pending;
    private static readonly TimeSpan PendingSignIn = TimeSpan.FromMinutes(10);

    public GoogleAccount(IAccountStore store, HttpClient client, string deviceLabel = "Windows")
    {
        this.store = store;
        supabase = new SupabaseClient(client);
        this.deviceLabel = deviceLabel;
        session = store.LoadSession();
        recordKey = session == null ? null : store.LoadRecordKey();
        if (session == null) store.DeleteRecordKey();
    }

    public Guid DeviceId => store.DeviceId;
    public bool SignedIn { get { lock (snapshotGate) return session != null; } }
    public AccountSnapshot Snapshot
    {
        get
        {
            lock (snapshotGate)
                return session == null ? new AccountSnapshot(false, false, false, false, null)
                    : new AccountSnapshot(true, session.Registered, session.Approved, recordKey != null, session.DisplayName);
        }
    }

    /// Step 1: the shell opens this URL in the system browser. A new attempt replaces the previous verifier.
    public object BeginSignIn()
    {
        var pkce = Pkce.Create();
        lock (snapshotGate) pending = (pkce, DateTimeOffset.UtcNow + PendingSignIn);
        return new { url = GoogleSignIn.AuthorizeUrl(pkce).AbsoluteUri };
    }

    /// Step 2: the browser returned ppomi://auth?code=… . Exchange it with the pending verifier, then register this device.
    /// Any earlier account on this installation is replaced together with its record key.
    public async Task<AccountSnapshot> CompleteSignIn(string callback, CancellationToken cancellation)
    {
        var code = GoogleSignIn.CodeFromCallback(callback) ?? throw new NativeFailure("sign_in_failed");
        Pkce pkce;
        lock (snapshotGate)
        {
            if (pending is not { } attempt || attempt.Expires < DateTimeOffset.UtcNow) throw new NativeFailure("sign_in_failed");
            pkce = attempt.Pkce; pending = null;
        }
        SupabaseTokens tokens;
        try { tokens = await supabase.Exchange(code, pkce.Verifier, cancellation); }
        catch (ServerRefusal) { throw new NativeFailure("sign_in_failed"); }
        var fresh = new GoogleSession(tokens.AccessToken, tokens.RefreshToken, tokens.ExpiresAt, tokens.Sub, tokens.DisplayName, false, false, null);
        await gate.WaitAsync(cancellation);
        try
        {
            lock (snapshotGate) { session = fresh; recordKey = null; }
            store.DeleteRecordKey();
            store.SaveSession(fresh);
            await RegisterLocked(cancellation);
            return Snapshot;
        }
        finally { gate.Release(); }
    }

    public void SignOut()
    {
        lock (snapshotGate) { session = null; recordKey = null; pending = null; }
        store.DeleteSession();
        store.DeleteRecordKey();
    }

    /// Ask the server where this device stands; once approved, fetch and unwrap the record key the Mac left for it.
    /// A revoked device registers again and returns to the pending state.
    public async Task<AccountSnapshot> Refresh(CancellationToken cancellation)
    {
        await gate.WaitAsync(cancellation);
        try
        {
            if (Current == null) return Snapshot;
            var token = await AccessTokenLocked(cancellation);
            if (Current is { Registered: false }) await RegisterLocked(cancellation);
            JsonElement context;
            try { context = await supabase.Rpc("ppomi_context", new { }, token, store.DeviceId, cancellation); }
            catch (ServerRefusal refusal) when (refusal.Status is 401 or 403)
            {
                if (refusal.Status == 401) throw new NativeFailure("server_auth");
                // Not an active device any more (owner revoked it): start over as a pending device.
                Update(current => current with { Registered = false, Approved = false });
                lock (snapshotGate) recordKey = null;
                store.DeleteRecordKey();
                await RegisterLocked(cancellation);
                return Snapshot;
            }
            catch (ServerRefusal) { throw new NativeFailure("server_rejected"); }
            var device = JsonArgs.Object(context, "device");
            if (!Guid.TryParse(JsonArgs.String(device, "id", 36), out var id) || id != store.DeviceId ||
                !Guid.TryParse(JsonArgs.String(JsonArgs.Object(context, "workspace"), "id", 36), out var workspace))
                throw new NativeFailure("server_auth");
            var approved = device.TryGetProperty("approved", out var flag) && flag.ValueKind == JsonValueKind.True;
            Update(current => current with { Registered = true, Approved = approved, WorkspaceId = workspace });
            if (approved && Current is { } && recordKey == null) await FetchKeyLocked(token, workspace, cancellation);
            if (!approved && recordKey != null) { lock (snapshotGate) recordKey = null; store.DeleteRecordKey(); }
            return Snapshot;
        }
        finally { gate.Release(); }
    }

    /// A valid bearer for the agent proxy; refreshed (and persisted) when within 30 seconds of expiry.
    public async Task<string> AccessToken(CancellationToken cancellation)
    {
        await gate.WaitAsync(cancellation);
        try { return await AccessTokenLocked(cancellation); }
        finally { gate.Release(); }
    }

    private GoogleSession? Current { get { lock (snapshotGate) return session; } }

    private void Update(Func<GoogleSession, GoogleSession> change)
    {
        GoogleSession? next;
        lock (snapshotGate)
        {
            if (session == null) return;
            next = change(session);
            if (next == session) return;
            session = next;
        }
        store.SaveSession(next);
    }

    private async Task<string> AccessTokenLocked(CancellationToken cancellation)
    {
        var current = Current ?? throw new NativeFailure("server_unconfigured");
        if (current.ExpiresAt > DateTimeOffset.UtcNow.AddSeconds(30)) return current.AccessToken;
        SupabaseTokens tokens;
        try { tokens = await supabase.Refresh(current.RefreshToken, cancellation); }
        catch (ServerRefusal refusal) when (refusal.Status is 400 or 401 or 403)
        {
            // The refresh token is dead (revoked or rotated elsewhere): this installation is signed out.
            SignOut();
            throw new NativeFailure("server_auth");
        }
        catch (ServerRefusal) { throw new NativeFailure("server_unavailable"); }
        if (tokens.Sub != current.Sub) { SignOut(); throw new NativeFailure("server_auth"); }
        Update(s => s with { AccessToken = tokens.AccessToken, RefreshToken = tokens.RefreshToken, ExpiresAt = tokens.ExpiresAt, DisplayName = tokens.DisplayName ?? s.DisplayName });
        return tokens.AccessToken;
    }

    private async Task RegisterLocked(CancellationToken cancellation)
    {
        var token = await AccessTokenLocked(cancellation);
        var publicKey = Convert.ToBase64String(X25519.PublicKey(store.DevicePrivateKey()));
        JsonElement reply;
        try
        {
            reply = await supabase.Rpc("ppomi_register_device",
                new { p_device_id = store.DeviceId, p_label = deviceLabel, p_platform = "windows", p_public_key = publicKey }, token, store.DeviceId, cancellation);
        }
        catch (ServerRefusal refusal) { throw new NativeFailure(refusal.Status is 401 or 403 ? "server_auth" : "server_rejected"); }
        var device = JsonArgs.Object(reply, "device");
        if (!Guid.TryParse(JsonArgs.String(device, "id", 36), out var id) || id != store.DeviceId ||
            !Guid.TryParse(JsonArgs.String(JsonArgs.Object(reply, "workspace"), "id", 36), out var workspace))
            throw new NativeFailure("server_auth");
        var approved = device.TryGetProperty("approved", out var flag) && flag.ValueKind == JsonValueKind.True;
        Update(current => current with { Registered = true, Approved = approved, WorkspaceId = workspace });
    }

    private async Task FetchKeyLocked(string token, Guid workspace, CancellationToken cancellation)
    {
        JsonElement reply;
        try { reply = await supabase.Rpc("ppomi_key_get", new { }, token, store.DeviceId, cancellation); }
        catch (ServerRefusal) { return; }   // the key is optional for the conversation; the next refresh retries
        if (!reply.TryGetProperty("found", out var found) || found.ValueKind != JsonValueKind.True) return;
        if (!Guid.TryParse(JsonArgs.String(reply, "workspace_id", 36), out var keyWorkspace) || keyWorkspace != workspace ||
            !Guid.TryParse(JsonArgs.String(reply, "key_id", 36), out var keyId))
            throw new NativeFailure("response_invalid");
        byte[] wrapped;
        try { wrapped = Convert.FromBase64String(JsonArgs.String(reply, "wrapped", 400)); }
        catch (FormatException) { throw new NativeFailure("response_invalid"); }
        var records = RecordKey.ParseRecords(JsonArgs.Object(reply, "records"));
        var key = KeyWrap.Unwrap(wrapped, store.DevicePrivateKey(), workspace, keyId);
        var value = new RecordKey(workspace, keyId, key, records);
        store.SaveRecordKey(value);
        lock (snapshotGate) recordKey = value;
    }
}
