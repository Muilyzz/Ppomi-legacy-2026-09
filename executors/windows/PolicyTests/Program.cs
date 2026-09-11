using System.Net;
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
Console.WriteLine($"PASS {passed} policy and proxy checks (synthetic only).");

static HttpResponseMessage JsonResponse(object value) => new(HttpStatusCode.OK)
{ Content = new StringContent(JsonSerializer.Serialize(value), Encoding.UTF8, "application/json") };

sealed class FakeHandler(Func<HttpRequestMessage, CancellationToken, Task<HttpResponseMessage>> respond) : HttpMessageHandler
{
    protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken) => respond(request, cancellationToken);
}
