using System.Net;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using Ppomi.Executor;

// Dependency-free tests run on macOS/Linux as well as Windows; no live account or device is touched.
var passed = 0;
void Check(bool condition, string name) { if (!condition) throw new Exception(name); passed++; }
void Reject(Action action, string name, string code = "invalid_request")
{
    try { action(); throw new Exception("Accepted: " + name); }
    catch (NativeFailure failure) { Check(failure.Code == code, name); }
}
async Task RejectAsync(Func<Task> action, string name, string code)
{
    try { await action(); throw new Exception("Accepted: " + name); }
    catch (NativeFailure failure) { Check(failure.Code == code, name); }
}
JsonElement Object(string value) { using var doc = JsonDocument.Parse(value); return doc.RootElement.Clone(); }
var deviceId = Guid.NewGuid();
byte[] Configuration(string? url = null, string? key = null, string? password = null) => JsonSerializer.SerializeToUtf8Bytes(new
{
    url = url ?? "https://synthetic.supabase.co", publishableKey = key ?? "sb_publishable_0123456789abcdef",
    email = "fixture@example.invalid", password = password ?? "synthetic-password", deviceId
});

Check(NativePolicy.RequestUri("https://example.invalid/base", "/v1/responses").AbsoluteUri == "https://example.invalid/base/v1/responses", "base path preserved");
Check(NativePolicy.ConfiguredEndpoint(null) == "https://ppomi-agent.vercel.app", "missing setting uses standard service");
Check(NativePolicy.ConfiguredEndpoint("") == "https://ppomi-agent.vercel.app", "empty setting uses standard service");
Check(NativePolicy.RequestUri(NativePolicy.ConfiguredEndpoint(""), "/v1/session").AbsoluteUri == "https://ppomi-agent.vercel.app/v1/session", "standard service route");
Check(NativePolicy.ConfiguredEndpoint("https://example.invalid/development/") == "https://example.invalid/development", "explicit development override retained");
Reject(() => NativePolicy.ConfiguredEndpoint("http://example.invalid"), "development override still requires HTTPS");
foreach (var endpoint in new[] { "http://example.invalid", "https://a@b.invalid", "https://example.invalid/#x", "https://example.invalid/?x=1",
    "https://example.invalid/a/../b", "https://example.invalid/%2e%2e/b", "https://example.invalid\\@evil.invalid", "https://example.invalid/\n" })
    Reject(() => NativePolicy.Endpoint(endpoint), "endpoint rejected");
foreach (var route in new[] { "/auth/v1/token", "//evil.invalid/v1/responses", "/v1/responses?next=x", "/v1/responses/../session", "/v1/responses/" })
    Reject(() => NativePolicy.RequestUri("https://example.invalid", route), "route rejected");
Check(NativePolicy.WorkspaceParts("reports/한글.txt", false).Length == 2, "Korean path");
Check(NativePolicy.WorkspaceParts("", true).Length == 0, "workspace root");
foreach (var path in new[] { "", "../x", "/absolute", "a//b", "a/./b", "C:/x", "a\\b", "file:secret", "file.", "file ",
    "NUL", "CON.txt", "aux", "COM1.log", "LPT².txt", "a/*", "a/\0", ".ppomi-write-fixture", string.Join('/', Enumerable.Repeat("a", 17)) })
    Reject(() => NativePolicy.WorkspaceParts(path, false), "unsafe path rejected");
Check(DeviceConfiguration.Decode(Configuration()).DeviceId == deviceId, "configuration accepted");
foreach (var url in new[] { "http://synthetic.supabase.co", "https://synthetic.supabase.co.evil.invalid", "https://evil.invalid", "https://synthetic.supabase.co/path", "https://synthetic.supabase.co?x=1", "https://synthetic.supabase.co:443" })
    Reject(() => DeviceConfiguration.Decode(Configuration(url)), "auth origin bound");
Reject(() => DeviceConfiguration.Decode(Configuration(key: "sb_secret_0123456789abcdef")), "secret key rejected");
Reject(() => DeviceConfiguration.Decode(Configuration(password: "short")), "short password rejected");
var servicePayload = Convert.ToBase64String("{\"role\":\"service_role\"}"u8.ToArray()).TrimEnd('=').Replace('+', '-').Replace('/', '_');
Reject(() => DeviceConfiguration.Decode(Configuration(key: "e30." + servicePayload + ".signature")), "service JWT rejected");
Reject(() => DeviceConfiguration.Decode(new byte[16385]), "config size bounded");
Check(NativePolicy.ProtectedLabel("결제 확인"), "payment protected");
Check(NativePolicy.ProtectedLabel("Send now"), "send protected");
Check(NativePolicy.IsCommandHost("PoWeRsHeLl.ExE"), "shell denied");
Check(!NativePolicy.ProtectedLabel("Search"), "normal label supported");

using var session = new NativeSession();
Reject(() => session.Capture(), "idle cannot execute", "session_ended");
session.Set(true, "text");
var oldLease = session.Capture();
Check(oldLease.Commit(() => 7) == 7, "active commit");
session.Set(false, "text");
Check(oldLease.Token.IsCancellationRequested, "stop cancels in-flight network");
session.Set(true, "voice");
Reject(oldLease.Check, "old lease cannot enter later session", "session_ended");
Reject(() => oldLease.Commit(() => true), "stale commit rejected", "session_ended");
Reject(() => session.Set(true, "text"), "duplicate start rejected");

var config = DeviceConfiguration.Decode(Configuration());
var requests = new List<(string Uri, string? Auth, string Body)>();
var handler = new FakeHandler(async (request, cancellation) =>
{
    requests.Add((request.RequestUri!.AbsoluteUri, request.Headers.Authorization?.ToString(), await request.Content!.ReadAsStringAsync(cancellation)));
    return request.RequestUri!.AbsolutePath switch
    {
        "/auth/v1/token" => JsonResponse(new { access_token = "synthetic-access-token", expires_in = 3600 }),
        "/rest/v1/rpc/ppomi_context" => JsonResponse(new { device = new { id = deviceId }, workspace = new { id = Guid.NewGuid() }, devices = Array.Empty<object>() }),
        "/v1/responses" => JsonResponse(new { output = "fixture response" }),
        _ => new HttpResponseMessage(HttpStatusCode.NotFound)
    };
});
using (var proxy = new ServerProxy(config, handler))
{
    var response = await proxy.Request("https://agent.example.invalid", "/v1/responses", Object("{\"input\":\"fixture\"}"), session.Capture());
    Check(response.GetProperty("output").GetString() == "fixture response", "agent proxy result");
    Check(requests.Count == 3 && requests[0].Auth == null && requests[2].Auth == "Bearer synthetic-access-token", "native authentication sequence");
    Check(!requests[2].Body.Contains(config.Password) && !requests[2].Body.Contains(config.PublishableKey), "credentials excluded from agent body");
    await proxy.Request("https://agent.example.invalid", "/v1/responses", Object("{}"), session.Capture());
    Check(requests.Count == 4, "token reused without reauth");
    await RejectAsync(() => proxy.Request("https://agent.example.invalid", "/arbitrary", Object("{}"), session.Capture()), "no arbitrary route", "invalid_request");
    Check(requests.Count == 4, "rejected route sent no request");
}

var agentCalls = 0;
using (var proxy = new ServerProxy(config, new FakeHandler((request, _) =>
{
    if (request.RequestUri!.AbsolutePath == "/auth/v1/token") return Task.FromResult(JsonResponse(new { access_token = "synthetic-access-token", expires_in = 3600 }));
    if (request.RequestUri.AbsolutePath == "/rest/v1/rpc/ppomi_context") return Task.FromResult(JsonResponse(new { device = new { id = Guid.NewGuid() }, workspace = new { id = Guid.NewGuid() }, devices = Array.Empty<object>() }));
    agentCalls++; return Task.FromResult(JsonResponse(new { ok = true }));
})))
    await RejectAsync(() => proxy.Request("https://agent.example.invalid", "/v1/responses", Object("{}"), session.Capture()), "wrong device rejected", "server_auth");
Check(agentCalls == 0, "unregistered device cannot reach agent");

var authCalls = 0;
using (var proxy = new ServerProxy(config, new FakeHandler((_, _) =>
{
    authCalls++;
    var redirect = new HttpResponseMessage(HttpStatusCode.TemporaryRedirect);
    redirect.Headers.Location = new Uri("https://evil.example.invalid");
    return Task.FromResult(redirect);
})))
    await RejectAsync(() => proxy.Request("https://agent.example.invalid", "/v1/responses", Object("{}"), session.Capture()), "auth redirect is an error", "server_auth");
Check(authCalls == 1, "redirect did not trigger proxy retry");

var startedRequest = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
using (var proxy = new ServerProxy(config, new FakeHandler(async (_, cancellation) =>
{
    startedRequest.TrySetResult();
    await Task.Delay(Timeout.InfiniteTimeSpan, cancellation);
    return JsonResponse(new { });
})))
{
    var pendingRequest = proxy.Request("https://agent.example.invalid", "/v1/responses", Object("{}"), session.Capture());
    await startedRequest.Task;
    session.Set(false, "voice");
    await RejectAsync(async () => await pendingRequest, "stop cancels authentication", "session_ended");
}
// --- X25519 (RFC 7748 §5.2 and §6.1 vectors) -----------------------------------------------------------------------------
Check(Convert.ToHexStringLower(X25519.ScalarMult(Convert.FromHexString("a546e36bf0527c9d3b16154b82465edd62144c0ac1fc5a18506a2244ba449ac4"),
    Convert.FromHexString("e6db6867583030db3594c1a424b15f7c726624ec26b3353b10a903a6d0ab1c4c"))) == "c3da55379de9c6908e94ea4df28d084f32eccf03491c71f754b4075577a28552", "rfc7748 vector 1");
Check(Convert.ToHexStringLower(X25519.ScalarMult(Convert.FromHexString("4b66e9d4d1b4673c5ad22691957d6af5c11b6421e0ea01d42ca4169e7918ba0d"),
    Convert.FromHexString("e5210f12786811d3f4b7959d0538ae2c31dbe7106fc03c3efc4cd549c715a493"))) == "95cbde9476e8907d7aade45cb4b873f88b595a68799fa152e6f8f7647aac7957", "rfc7748 vector 2");
var alice = Convert.FromHexString("77076d0a7318a57d3c16c17251b26645df4c2f87ebc0992ab177fba51db92c2a");
var bob = Convert.FromHexString("5dab087e624a8a4b79e17f8b83800ee66f3bb1292618b6fd1c2f8b27ff88e0eb");
Check(Convert.ToHexStringLower(X25519.PublicKey(alice)) == "8520f0098930a754748b7ddcb43ef75a0dbf3a0d26381af4eba4a98eaa9b4e6a", "alice public key");
Check(Convert.ToHexStringLower(X25519.PublicKey(bob)) == "de9edb7d7b7dc1b4d35b61c2ece435373f8343c85b78674dadfc7e146f882b4f", "bob public key");
Check(Convert.ToHexStringLower(X25519.ScalarMult(alice, X25519.PublicKey(bob))) == "4a5d9d5ba4ce2de1728e3bf480350f25e07e21c947d19e3376f09b3c1e161742", "shared secret agrees");
Check(X25519.ScalarMult(alice, X25519.PublicKey(bob)).SequenceEqual(X25519.ScalarMult(bob, X25519.PublicKey(alice))), "agreement is symmetric");
Check(X25519.ScalarMult(alice, new byte[32]).All(b => b == 0), "low-order point yields the all-zero secret that callers reject");
Reject(() => X25519.ScalarMult(alice, new byte[31]), "short point rejected");

// --- KeyWrap: interop fixture produced by WebCrypto (the Mac/hub formulas) and a local round trip -------------------------
var fixtureWorkspace = Guid.Parse("6f1c2a3b-4d5e-4f60-8a7b-9c0d1e2f3a4b");
var fixtureKeyId = Guid.Parse("0a1b2c3d-4e5f-4a6b-8c7d-9e8f7a6b5c4d");
var fixturePrivate = Convert.FromHexString("086ca96df1357ae78445ae2f9e8f62350cd0f15a47a816a879c4ec5f7d0e606e");
Check(Convert.ToHexStringLower(X25519.PublicKey(fixturePrivate)) == "3ada813c08afbcaa746136c36f43f7daa9899c6a7967bac76fe31a8eb390dd59", "fixture public key matches WebCrypto export");
var fixtureWrapped = Convert.FromBase64String("T72J/CJYR9oLIr9n8IsR7vE7GMWcpYBjkkE9q4Jd8hKqDRkTsfEORuaKWlYdFwOS0cNDNbpt1A7XPv13YKHBs+o+OQH7BvSwiQWZTqgUfeErDQpwxBwxTgy0qGU=");
Check(Convert.ToHexStringLower(KeyWrap.Unwrap(fixtureWrapped, fixturePrivate, fixtureWorkspace, fixtureKeyId)) == "306036c890ef616bfe80ad6b2bfe2e2fb48466b864747b93fe326fa6ee5a2713", "unwraps a key wrapped by another implementation");
Reject(() => KeyWrap.Unwrap(fixtureWrapped, fixturePrivate, fixtureWorkspace, Guid.NewGuid()), "wrong key id fails authentication", "response_invalid");
Reject(() => KeyWrap.Unwrap(fixtureWrapped, fixturePrivate, Guid.NewGuid(), fixtureKeyId), "wrong workspace fails authentication", "response_invalid");
Reject(() => KeyWrap.Unwrap(fixtureWrapped, bob, fixtureWorkspace, fixtureKeyId), "another device's private key cannot unwrap", "response_invalid");
var tampered = (byte[])fixtureWrapped.Clone(); tampered[50] ^= 1;
Reject(() => KeyWrap.Unwrap(tampered, fixturePrivate, fixtureWorkspace, fixtureKeyId), "tampered ciphertext rejected", "response_invalid");
Reject(() => KeyWrap.Unwrap(fixtureWrapped[..91], fixturePrivate, fixtureWorkspace, fixtureKeyId), "wrong blob size rejected", "response_invalid");
var recordKeyBytes = RandomNumberGenerator.GetBytes(32);
var roundTrip = KeyWrap.Wrap(recordKeyBytes, X25519.PublicKey(alice), fixtureWorkspace, fixtureKeyId);
Check(roundTrip.Length == KeyWrap.WrappedSize && KeyWrap.Unwrap(roundTrip, alice, fixtureWorkspace, fixtureKeyId).SequenceEqual(recordKeyBytes), "wrap/unwrap round trip");
Check(!Convert.ToBase64String(roundTrip).Contains(Convert.ToBase64String(recordKeyBytes)[..20]), "wrapped blob does not contain the key");

// --- Google sign-in building blocks -------------------------------------------------------------------------------------
var pkce = Pkce.Create();
Check(pkce.Challenge == Pkce.Base64Url(SHA256.HashData(Encoding.ASCII.GetBytes(pkce.Verifier))) && pkce.Verifier.Length >= 43, "pkce challenge is S256 of the verifier");
var authorize = GoogleSignIn.AuthorizeUrl(pkce);
Check(authorize.Scheme == "https" && authorize.Host == "nafutfqfbbmknzmyspus.supabase.co" && authorize.AbsolutePath == "/auth/v1/authorize", "authorize endpoint");
Check(authorize.Query.Contains("provider=google") && authorize.Query.Contains("redirect_to=ppomi%3A%2F%2Fauth") && authorize.Query.Contains("code_challenge_method=s256")
    && authorize.Query.Contains("code_challenge=" + pkce.Challenge) && !authorize.Query.Contains(pkce.Verifier), "authorize query carries the challenge, never the verifier");
Check(GoogleSignIn.CodeFromCallback("ppomi://auth?code=synthetic.code-1234_ABC") == "synthetic.code-1234_ABC", "callback code extracted");
Check(GoogleSignIn.CodeFromCallback("ppomi://auth/?code=synthetic-code-1234&state=ignored") == "synthetic-code-1234", "callback tolerates other parameters");
foreach (var callback in new[] { "https://auth?code=synthetic-code-1234", "ppomi://evil?code=synthetic-code-1234", "ppomi://auth?error=access_denied",
    "ppomi://auth?code=a&code=b", "ppomi://auth?code=short", "ppomi://auth?code=has%20space", "ppomi://auth", "ppomi://user@auth?code=synthetic-code-1234", "not a url" })
    Check(GoogleSignIn.CodeFromCallback(callback) == null, "callback rejected: " + callback);
// The exact shapes GoTrue sends to redirect_to=ppomi://auth: a PKCE success carries the auth code (a uuid) in the query;
// an error is repeated in query and fragment; a fragment token set belongs to the implicit flow and never completes PKCE.
const string gotrueCode = "0f2d5c1e-9a7b-4c3d-8e2f-1a2b3c4d5e6f";
const string gotrueError = "error=access_denied&error_code=otp_expired&error_description=Email+link+is+invalid+or+has+expired";
Check(GoogleSignIn.CodeFromCallback("ppomi://auth?code=" + gotrueCode) == gotrueCode, "gotrue pkce success: code in the query");
Check(GoogleSignIn.CodeFromCallback("ppomi://auth/?code=" + gotrueCode) == gotrueCode, "browser-normalised trailing slash");
Check(GoogleSignIn.CodeFromCallback("ppomi://auth?" + gotrueError + "#" + gotrueError + "&sb=") == null, "gotrue error in query and fragment");
Check(GoogleSignIn.CodeFromCallback("ppomi://auth#access_token=synthetic-access&refresh_token=synthetic-refresh&token_type=bearer") == null, "implicit fragment never completes pkce");
Check(GoogleSignIn.CodeFromCallback("ppomi://auth#code=" + gotrueCode) == null, "a code hidden in the fragment is not a callback code");
Check(GoogleSignIn.CodeFromCallback("ppomi://auth%3Fcode%3D" + gotrueCode) == null, "over-encoded handoff is not a code");
var subject = Guid.NewGuid();
string Jwt(object payload) => "e30." + Pkce.Base64Url(JsonSerializer.SerializeToUtf8Bytes(payload)) + ".signature";
var parsed = GoogleSignIn.ParseTokens(Object(JsonSerializer.Serialize(new { access_token = Jwt(new { sub = subject, email = "fixture@example.invalid", user_metadata = new { full_name = "합성 사용자" } }),
    refresh_token = "synthetic-refresh", expires_in = 3600 })));
Check(parsed.Sub == subject && parsed.DisplayName == "합성 사용자" && parsed.RefreshToken == "synthetic-refresh" && parsed.ExpiresAt > DateTimeOffset.UtcNow.AddMinutes(50), "tokens parsed with display name only");
Reject(() => GoogleSignIn.ParseTokens(Object(JsonSerializer.Serialize(new { access_token = Jwt(new { email = "x@example.invalid" }), refresh_token = "r", expires_in = 3600 }))), "token without subject rejected", "server_auth");
Reject(() => GoogleSignIn.ParseTokens(Object(JsonSerializer.Serialize(new { access_token = "not a jwt at all!", refresh_token = "r", expires_in = 3600 }))), "malformed access token rejected", "server_auth");

// --- Sign-in → pending → approval → wrapped key, against a fake Supabase and agent ------------------------------------------
var memory = new MemoryStore();
var server = new FakeSupabase(subject);
using var http = NativeHttp.Create(new FakeHandler(server.Respond));
var google = new GoogleAccount(memory, http, "Windows (FIXTURE)");
var windowsId = memory.DeviceId;
Check(!google.Snapshot.SignedIn && !google.Snapshot.Configured, "fresh installation is signed out");
Reject(() => google.CompleteSignIn("ppomi://auth?code=synthetic-code-1234", CancellationToken.None).GetAwaiter().GetResult(), "callback without a pending attempt rejected", "sign_in_failed");
var begun = JsonSerializer.SerializeToElement(google.BeginSignIn());
var authorizeUrl = new Uri(begun.GetProperty("url").GetString()!);
server.Challenge = authorizeUrl.Query.Split('&').Select(p => p.Split('=')).First(p => p[0].TrimStart('?') == "code_challenge")[1];
await RejectAsync(() => google.CompleteSignIn("https://auth?code=synthetic-code-1234", CancellationToken.None), "foreign callback scheme rejected", "sign_in_failed");
server.AcceptCode = "synthetic-code-1234";
begun = JsonSerializer.SerializeToElement(google.BeginSignIn());   // a rejected callback consumed the attempt; a new one starts cleanly
server.Challenge = new Uri(begun.GetProperty("url").GetString()!).Query.Split('&').Select(p => p.Split('=')).First(p => p[0].TrimStart('?') == "code_challenge")[1];
var pendingSnapshot = await google.CompleteSignIn("ppomi://auth?code=synthetic-code-1234", CancellationToken.None);
Check(pendingSnapshot is { SignedIn: true, Registered: true, Approved: false, PendingApproval: true, Configured: false, RecordKey: false }, "sign-in registers the device as pending");
Check(pendingSnapshot.DisplayName == "합성 사용자", "display name comes from the token");
Check(server.Registration is { } registration && registration.GetProperty("p_platform").GetString() == "windows" && registration.GetProperty("p_label").GetString() == "Windows (FIXTURE)"
    && registration.GetProperty("p_device_id").GetString() == windowsId.ToString("D")
    && registration.GetProperty("p_public_key").GetString() == Convert.ToBase64String(X25519.PublicKey(memory.DevicePrivateKey())), "registration carries the device public key and platform");
Check(server.Requests.Where(r => r.Path.StartsWith("/rest/")).All(r => r.Device == windowsId.ToString("D") && r.Auth == "Bearer " + server.AccessToken && r.ApiKey == PpomiServer.PublishableKey), "every RPC carries apikey, bearer and X-Ppomi-Device");
Check(server.Requests.First(r => r.Path.StartsWith("/auth/v1/token")).Body.Contains("code_verifier") && server.ExchangeVerified, "code exchange used the verifier matching the challenge");
Check(memory.Session is { Registered: true, Approved: false } && memory.Session.AccessToken == server.AccessToken, "pending session persisted to the store");
var presentation = JsonSerializer.Serialize(pendingSnapshot.Json) + JsonSerializer.Serialize(google.Snapshot.Json);
Check(!presentation.Contains(server.AccessToken) && !presentation.Contains("synthetic-refresh") && !presentation.Contains("fixture@example.invalid"), "presentation state carries no token or email");

using (var proxy = new ServerProxy(null, account: google, sharedClient: http))
{
    Check(proxy.Configured && !proxy.Connected, "signed in but not connected before approval");
    session.Set(false, "text"); session.Set(true, "text");
    await RejectAsync(() => proxy.Request("https://agent.example.invalid", "/v1/responses", Object("{}"), session.Capture()), "pending device cannot reach the agent", "server_auth");
    Check(server.Requests.All(r => !r.Path.StartsWith("/v1/")), "no agent request was sent while pending");

    var refreshed = await google.Refresh(CancellationToken.None);
    Check(refreshed is { PendingApproval: true, RecordKey: false } && server.Requests.Count(r => r.Path.EndsWith("ppomi_context")) == 1, "refresh polls the context while pending");
    Check(!server.Requests.Any(r => r.Path.EndsWith("ppomi_key_get")), "no key fetch before approval");

    server.Approved = true;   // the owner pressed 승인 on the Mac; the Mac wrapped the key for this device
    server.Wrapped = Convert.ToBase64String(KeyWrap.Wrap(recordKeyBytes, X25519.PublicKey(memory.DevicePrivateKey()), server.Workspace, server.KeyId));
    var approved = await google.Refresh(CancellationToken.None);
    Check(approved is { Configured: true, PendingApproval: false, RecordKey: true }, "approval turns the device into a connected member");
    Check(memory.RecordKey is { } stored && stored.Key.SequenceEqual(recordKeyBytes) && stored.KeyId == server.KeyId && stored.WorkspaceId == server.Workspace && stored.Records["ledger"] == server.LedgerRecord, "wrapped key unwrapped and stored");
    Check(memory.Session is { Approved: true }, "approval persisted");
    Check(proxy.Connected, "proxy reports connected after approval");
    var response = await proxy.Request("https://agent.example.invalid", "/v1/responses", Object("{\"input\":\"fixture\"}"), session.Capture());
    var agentRequest = server.Requests.Last(r => r.Path == "/v1/responses");
    Check(response.GetProperty("output").GetString() == "fixture response" && agentRequest.Auth == "Bearer " + server.AccessToken && agentRequest.Device == windowsId.ToString("D") && agentRequest.ApiKey == null, "agent proxy sends bearer and X-Ppomi-Device, no apikey");
    Check(!agentRequest.Body.Contains("synthetic-refresh") && !agentRequest.Body.Contains(Convert.ToBase64String(recordKeyBytes)), "agent body carries no secret");

    // Revocation on the Mac: the context refuses, the device re-registers as pending and drops the record key.
    server.Revoked = true;
    var revoked = await google.Refresh(CancellationToken.None);
    Check(revoked is { SignedIn: true, Registered: true, Approved: false, RecordKey: false } && memory.RecordKey == null, "revoked device returns to pending without the key");
    Check(server.Requests.Count(r => r.Path.EndsWith("ppomi_register_device")) == 2, "revocation triggers exactly one new registration");
    server.Revoked = false;

    // Token refresh: an expiring session is renewed and persisted before the request goes out.
    memory.Session = memory.Session! with { ExpiresAt = DateTimeOffset.UtcNow.AddSeconds(5), Approved = true };
    server.Approved = true;
    var renewed = new GoogleAccount(memory, http, "Windows (FIXTURE)");
    Check(renewed.Snapshot is { SignedIn: true, Approved: true }, "session restored from the store");
    var token = await renewed.AccessToken(CancellationToken.None);
    Check(token == server.AccessToken && server.Requests.Last(r => r.Path.StartsWith("/auth/v1/token")).Path.EndsWith("grant_type=refresh_token") && memory.Session!.AccessToken == token, "expiring session refreshed and persisted");
    Check(memory.Session!.ExpiresAt > DateTimeOffset.UtcNow.AddMinutes(30), "new expiry recorded");
    Check(await renewed.AccessToken(CancellationToken.None) == token && server.Requests.Count(r => r.Path.EndsWith("grant_type=refresh_token")) == 1, "fresh token reused without another refresh");

    // A dead refresh token signs the installation out instead of looping.
    memory.Session = memory.Session! with { ExpiresAt = DateTimeOffset.UtcNow.AddSeconds(-1), RefreshToken = "revoked-elsewhere" };
    server.RefuseRefresh = true;
    var dead = new GoogleAccount(memory, http, "Windows (FIXTURE)");
    await RejectAsync(() => dead.AccessToken(CancellationToken.None), "dead refresh token reported as authentication failure", "server_auth");
    Check(!dead.SignedIn && memory.Session == null && memory.RecordKey == null, "dead refresh token signs out and clears the stored key");
    server.RefuseRefresh = false;
}
google.SignOut();
Check(!google.SignedIn && memory.Session == null && memory.DeviceId == windowsId, "sign-out clears the session but keeps the stable device id");
Reject(() => google.CompleteSignIn("ppomi://auth?code=synthetic-code-1234", CancellationToken.None).GetAwaiter().GetResult(), "sign-out also cancels a pending attempt", "sign_in_failed");
server.RefuseExchange = true;
google.BeginSignIn();
await RejectAsync(() => google.CompleteSignIn("ppomi://auth?code=synthetic-code-1234", CancellationToken.None), "exchange refused by the server is a sign-in failure", "sign_in_failed");
Check(!google.SignedIn && memory.Session == null, "a failed exchange leaves no session behind");
Console.WriteLine($"PASS {passed} policy and proxy checks (synthetic only).");

static HttpResponseMessage JsonResponse(object value) => Fixture.Json(value);

static class Fixture
{
    public static HttpResponseMessage Json(object value) => new(HttpStatusCode.OK)
    { Content = new StringContent(JsonSerializer.Serialize(value), Encoding.UTF8, "application/json") };
}

sealed class MemoryStore : IAccountStore
{
    public Guid DeviceId { get; } = Guid.NewGuid();
    private readonly byte[] privateKey = RandomNumberGenerator.GetBytes(32);
    public GoogleSession? Session;
    public RecordKey? RecordKey;
    public byte[] DevicePrivateKey() => (byte[])privateKey.Clone();
    public GoogleSession? LoadSession() => Session == null ? null : GoogleSession.Decode(Session.Encode());   // round-trips the on-disk encoding
    public void SaveSession(GoogleSession session) => Session = session;
    public void DeleteSession() => Session = null;
    public RecordKey? LoadRecordKey() => RecordKey == null ? null : Ppomi.Executor.RecordKey.Decode(RecordKey.Encode());
    public void SaveRecordKey(RecordKey key) => RecordKey = key;
    public void DeleteRecordKey() => RecordKey = null;
}

/// Fake Supabase Auth + RPC + agent endpoint. Records every request so the tests can assert headers and bodies.
sealed class FakeSupabase(Guid subject)
{
    public sealed record Seen(string Path, string? Auth, string? Device, string? ApiKey, string Body);
    public readonly List<Seen> Requests = [];
    public string? Challenge, AcceptCode;
    public bool ExchangeVerified, Approved, Revoked, RefuseRefresh, RefuseExchange;
    public string? Wrapped;
    public JsonElement? Registration;
    public readonly Guid Workspace = Guid.NewGuid(), KeyId = Guid.NewGuid(), LedgerRecord = Guid.NewGuid();
    private int issued;
    public string AccessToken { get; private set; } = "";

    private string Issue()
    {
        issued++;
        AccessToken = "e30." + Pkce.Base64Url(JsonSerializer.SerializeToUtf8Bytes(new { sub = subject, email = "fixture@example.invalid", user_metadata = new { full_name = "합성 사용자" }, n = issued })) + ".signature";
        return AccessToken;
    }

    public async Task<HttpResponseMessage> Respond(HttpRequestMessage request, CancellationToken cancellation)
    {
        var body = request.Content == null ? "" : await request.Content.ReadAsStringAsync(cancellation);
        var path = request.RequestUri!.PathAndQuery;
        Requests.Add(new Seen(path, request.Headers.Authorization?.ToString(), request.Headers.TryGetValues("X-Ppomi-Device", out var d) ? d.First() : null,
            request.Headers.TryGetValues("apikey", out var k) ? k.First() : null, body));
        using var json = JsonDocument.Parse(body.Length == 0 ? "{}" : body);
        var args = json.RootElement;
        if (path == "/auth/v1/token?grant_type=pkce")
        {
            if (RefuseExchange) return new HttpResponseMessage(HttpStatusCode.BadRequest);
            var verifier = args.GetProperty("code_verifier").GetString()!;
            ExchangeVerified = Pkce.Base64Url(SHA256.HashData(Encoding.ASCII.GetBytes(verifier))) == Challenge && args.GetProperty("auth_code").GetString() == AcceptCode;
            return ExchangeVerified ? Fixture.Json(new { access_token = Issue(), refresh_token = "synthetic-refresh", expires_in = 3600 }) : new HttpResponseMessage(HttpStatusCode.BadRequest);
        }
        if (path == "/auth/v1/token?grant_type=refresh_token")
            return RefuseRefresh ? new HttpResponseMessage(HttpStatusCode.BadRequest) : Fixture.Json(new { access_token = Issue(), refresh_token = "synthetic-refresh-2", expires_in = 3600 });
        if (request.Headers.Authorization?.ToString() != "Bearer " + AccessToken) return new HttpResponseMessage(HttpStatusCode.Unauthorized);
        var device = Guid.Parse(request.Headers.GetValues("X-Ppomi-Device").First());
        switch (path)
        {
            case "/rest/v1/rpc/ppomi_register_device":
                Registration = args.Clone();
                if (Revoked) { Revoked = false; Approved = false; }   // a revived device waits for approval again (migration rule)
                return Fixture.Json(new { workspace = new { id = Workspace, name = "뽀미" }, device = new { id = device, label = args.GetProperty("p_label").GetString(), platform = "windows", approved = Approved } });
            case "/rest/v1/rpc/ppomi_context":
                if (Revoked) return new HttpResponseMessage(HttpStatusCode.Forbidden);
                return Fixture.Json(new { workspace = new { id = Workspace, name = "뽀미" }, device = new { id = device, label = "Windows", platform = "windows", approved = Approved },
                    devices = new object[] { new { id = device, label = "Windows", platform = "windows", approved = Approved } } });
            case "/rest/v1/rpc/ppomi_key_get":
                return Approved && Wrapped != null
                    ? Fixture.Json(new { found = true, workspace_id = Workspace, key_id = KeyId, records = new Dictionary<string, string> { ["ledger"] = LedgerRecord.ToString("D") }, wrapped = Wrapped })
                    : Fixture.Json(new { found = false });
            case "/v1/responses":
                return Fixture.Json(new { output = "fixture response" });
            default:
                return new HttpResponseMessage(HttpStatusCode.NotFound);
        }
    }
}

sealed class FakeHandler(Func<HttpRequestMessage, CancellationToken, Task<HttpResponseMessage>> respond) : HttpMessageHandler
{
    protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken) => respond(request, cancellationToken);
}
