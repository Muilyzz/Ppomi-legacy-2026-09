using System.Collections.Concurrent;
using System.Diagnostics;
using System.Text;
using System.Text.Json;

namespace Ppomi.Executor;

internal static class Program
{
    private static readonly object OutputGate = new();
    private static readonly JsonSerializerOptions JsonOptions = new() { PropertyNamingPolicy = JsonNamingPolicy.CamelCase };
    private const int MaxLine = 2 * 1024 * 1024;

    public static async Task<int> Main(string[] arguments)
    {
        Console.InputEncoding = new UTF8Encoding(false, true);
        Console.OutputEncoding = new UTF8Encoding(false, true);
        if (!OperatingSystem.IsWindows()) return 64;
        try
        {
            var ownerPid = ParseOwner(arguments);
            if (WindowsControl.IsElevated(Process.GetCurrentProcess().Handle)) return 77;
            using var host = new ExecutorHost(ownerPid);
            using var pending = new SemaphoreSlim(32);
            var ids = new HashSet<string>(StringComparer.Ordinal);
            var tasks = new ConcurrentDictionary<long, Task>();
            long sequence = 0;
            using var input = new StreamReader(Console.OpenStandardInput(), new UTF8Encoding(false, true), false, 8192);
            await foreach (var line in ReadLines(input))
            {
                string? id = null;
                try
                {
                    using var document = JsonDocument.Parse(line, new JsonDocumentOptions { MaxDepth = 64 });
                    var request = document.RootElement;
                    id = JsonArgs.String(request, "id", 160);
                    if (ids.Count >= 50000 || !ids.Add(id)) throw new NativeFailure("invalid_request");
                    var method = JsonArgs.String(request, "method", 80);
                    var args = JsonArgs.Object(request, "args").Clone();
                    // Stop always remains available even when all operation slots are occupied.
                    if (method == "sessionState")
                    {
                        Write(new { id, result = await host.Dispatch(method, args) });
                        continue;
                    }
                    // End/start and management are dispatched synchronously at receipt, before queued tools.
                    // Async request bodies capture their native session lease before their first await.
                    if (!pending.Wait(0)) throw new NativeFailure("tool_failed");
                    var key = Interlocked.Increment(ref sequence);
                    var task = Handle(host, id, method, args, pending);
                    tasks[key] = task;
                    _ = task.ContinueWith(_ => tasks.TryRemove(key, out var ignored), TaskScheduler.Default);
                }
                catch (Exception error)
                {
                    if (id != null) Failure(id, error);
                    // Invalid framing without a usable id cannot be replied to safely.
                }
            }
            host.Stop();
            // Exit on parent EOF: no restoration or automatic replay of an interrupted session.
            return 0;
        }
        catch { return 70; } // No raw exception, path, screen content, or credential on stdout/stderr.
    }

    private static async Task Handle(ExecutorHost host, string id, string method, JsonElement args, SemaphoreSlim pending)
    {
        try { Write(new { id, result = await host.Dispatch(method, args) }); }
        catch (Exception error) { Failure(id, error); }
        finally { pending.Release(); }
    }

    private static void Failure(string id, Exception error)
    {
        var code = error is NativeFailure failure ? failure.Code : error is OperationCanceledException ? "session_ended" : "tool_failed";
        Write(new { id, error = new { code, message = code } });
    }

    public static void Write(object value)
    {
        var json = JsonSerializer.Serialize(value, JsonOptions);
        lock (OutputGate) { Console.Out.WriteLine(json); Console.Out.Flush(); }
    }

    private static int ParseOwner(string[] arguments)
    {
        int owner = 0;
        for (var i = 0; i < arguments.Length; i++)
        {
            if (arguments[i] == "--executor") continue;
            if (arguments[i] == "--owner-pid" && ++i < arguments.Length && int.TryParse(arguments[i], out owner) && owner > 0) continue;
            throw new NativeFailure("invalid_request");
        }
        // Packaging must supply the shell PID. Failing closed is safer than accidentally exposing its UI.
        if (owner <= 0 || owner == Environment.ProcessId) throw new NativeFailure("invalid_request");
        using var process = Process.GetProcessById(owner);
        if (process.HasExited || process.SessionId != Process.GetCurrentProcess().SessionId) throw new NativeFailure("invalid_request");
        return owner;
    }

    private static async IAsyncEnumerable<string> ReadLines(StreamReader input)
    {
        var buffer = new char[8192];
        var line = new StringBuilder();
        while (true)
        {
            var count = await input.ReadAsync(buffer);
            if (count == 0) yield break;
            for (var i = 0; i < count; i++)
            {
                var character = buffer[i];
                if (character == '\n') { yield return line.ToString().TrimEnd('\r'); line.Clear(); }
                else { if (line.Length >= MaxLine) throw new NativeFailure("invalid_request"); line.Append(character); }
            }
        }
    }
}

internal sealed class ExecutorHost : IDisposable
{
    private readonly NativeSession session = new();
    private readonly DeviceStore store = new();
    private readonly WindowsWorkspace workspace;
    private readonly WindowsControl control;
    private readonly AutomationWorker automation = new();
    private readonly GoogleAccount account;
    private readonly ServerProxy server;
    private readonly SemaphoreSlim tools = new(1, 1);
    private readonly SemaphoreSlim management = new(1, 1);
    private readonly CancellationTokenSource monitor = new();
    private string endpoint;
    /// The email/password device-file import is a developer compatibility path. It exists only when the shell was started with this flag.
    private static readonly bool DeveloperDeviceImport = Environment.GetEnvironmentVariable("PPOMI_DEVELOPER_DEVICE_IMPORT") == "1";
    private static readonly string[] ToolNames = ["device_status", "app_list", "app_open", "screen_read", "ui_tap", "ui_type", "ui_scroll", "file_list", "file_read", "file_write"];

    public ExecutorHost(int ownerPid)
    {
        control = new WindowsControl(ownerPid);
        workspace = new WindowsWorkspace(Path.Combine(store.DirectoryPath, "workspace"));
        var http = NativeHttp.Create();
        account = new GoogleAccount(store, http, DeviceLabel());
        server = new ServerProxy(DeveloperDeviceImport ? store.Load() : null, account: account, sharedClient: http);
        endpoint = store.LoadEndpoint();
        _ = Task.Run(() => Monitor(monitor.Token));
    }

    /// Display label for the owner's approval list ("Windows (DESKTOP-…)"), never an identifier.
    private static string DeviceLabel()
    {
        var machine = Environment.MachineName;
        return machine.Length is >= 1 and <= 63 && machine.All(c => char.IsLetterOrDigit(c) || c == '-' || c == '_') ? $"Windows ({machine})" : "Windows";
    }

    /// Presentation only: sign-in and approval state, never tokens or the account email.
    private object Authentication()
    {
        var snapshot = account.Snapshot;
        if (!snapshot.SignedIn && server.LegacyConfigured)
            return new { method = "deviceConfigImport", developerOnly = true, signedIn = false, approved = false, pendingApproval = false, googleSignIn = true };
        return new { method = "google", developerOnly = false, signedIn = snapshot.SignedIn, approved = snapshot.Approved,
            pendingApproval = snapshot.PendingApproval, displayName = snapshot.DisplayName, googleSignIn = true };
    }

    /// While a signed-in device waits for the owner, ask the server every 15 seconds; once approved, recheck rarely (revocation).
    private async Task Monitor(CancellationToken cancellation)
    {
        var delay = TimeSpan.FromSeconds(3);
        while (!cancellation.IsCancellationRequested)
        {
            try { await Task.Delay(delay, cancellation); } catch (OperationCanceledException) { return; }
            var snapshot = account.Snapshot;
            if (!snapshot.SignedIn) { delay = TimeSpan.FromSeconds(30); continue; }
            try { snapshot = await account.Refresh(cancellation); delay = snapshot.Configured && snapshot.RecordKey ? TimeSpan.FromMinutes(5) : TimeSpan.FromSeconds(15); }
            catch (OperationCanceledException) { return; }
            catch (Exception) { delay = TimeSpan.FromSeconds(45); }   // network or server trouble: keep the last known state, retry later
        }
    }

    public async Task<object> Dispatch(string method, JsonElement args)
    {
        switch (method)
        {
            case "bootstrap":
                return new { platform = "windows", deviceLabel = "Windows", configured = server.Connected, endpoint,
                    authentication = Authentication(),
                    executor = new { googleSignIn = true, developmentDeviceImport = DeveloperDeviceImport, nativeAutomation = true },
                    tools = ToolNames, accessibility = true, bankProfileSupported = false,
                    controlApps = await automation.Run(control.ControlApps),
                    toolGuide = "This is a local Windows executor. app_list enumerates visible running applications, not installed packages. app_open activates an existing allowed application; it does not launch an executable. Ask the user to open an absent application and allow it in Ppomi settings while the session is idle. Grants expire when that application process restarts. Only UI Automation Invoke, Value, and a single Scroll target are supported. Read a fresh screen before every mutation. Password, protected labels, command/system hosts, elevated and Ppomi windows are rejected. Do not bypass a refusal using other elements. Unknown/custom-drawn controls are unsupported. file tools are UTF-8 files in the local Windows Ppomi workspace; no Mac, remote desktop, Parallels, shell commands, arbitrary filesystem, browser debugging, or coordinate input is available. Never automatically retry an uncertain mutation." };
            case "sessionState":
                if (!args.TryGetProperty("active", out var active) || active.ValueKind is not (JsonValueKind.True or JsonValueKind.False)) throw new NativeFailure("invalid_request");
                if (management.CurrentCount == 0) throw new NativeFailure("invalid_request");
                session.Set(active.GetBoolean(), JsonArgs.String(args, "mode", 16));
                control.Invalidate();
                return new { active = session.Active, mode = session.Mode };
            case "executorStatus":
                return new { platform = "windows", active = session.Active, mode = session.Mode, approval = (object?)null, configured = server.Connected,
                    account = account.Snapshot.Json,
                    capabilities = new { configureDevice = DeveloperDeviceImport, developmentDeviceImport = DeveloperDeviceImport, googleSignIn = true, controlApps = true, nativeAutomation = true,
                        fileWorkspace = true, bankProfile = false, approval = false },
                    availableApps = await automation.Run(control.AvailableApps) };
            case "setControlApps":
            case "configureDevice":
            case "setEndpoint":
            case "beginSignIn":
            case "completeSignIn":
            case "signOut":
            case "refreshAccount":
                if (!await management.WaitAsync(0)) throw new NativeFailure("invalid_request");
                try
                {
                    if (session.Active) throw new NativeFailure("protected_action");
                    // Account changes are trusted local UI operations. The browser round trip itself happens in the shell.
                    if (method == "beginSignIn") return account.BeginSignIn();
                    if (method == "completeSignIn" || method == "refreshAccount")
                    {
                        using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(method == "completeSignIn" ? 90 : 45));
                        AccountSnapshot snapshot;
                        try
                        {
                            snapshot = method == "completeSignIn" ? await account.CompleteSignIn(JsonArgs.String(args, "callback", 4096), timeout.Token)
                                : account.SignedIn ? await account.Refresh(timeout.Token) : account.Snapshot;
                        }
                        catch (OperationCanceledException) { throw new NativeFailure("server_unavailable"); }
                        return new { configured = snapshot.Configured, account = snapshot.Json };
                    }
                    if (method == "signOut") { account.SignOut(); return new { signedOut = true, account = account.Snapshot.Json }; }
                    if (method == "setControlApps")
                    {
                        if (!args.TryGetProperty("packageNames", out var names) || names.ValueKind != JsonValueKind.Array || names.GetArrayLength() > 100)
                            throw new NativeFailure("invalid_request");
                        var ids = names.EnumerateArray().Select(item => item.ValueKind == JsonValueKind.String && item.GetString()!.Length <= 160
                            ? item.GetString()! : throw new NativeFailure("invalid_request")).ToArray();
                        await automation.Run(() => { control.SetAllowed(ids); return true; });
                        return new { updated = true };
                    }
                    if (method == "configureDevice")
                    {
                        if (!DeveloperDeviceImport) throw new NativeFailure("invalid_request");
                        server.Configure(store.Import(JsonArgs.String(args, "path", 32768)));
                        return new { configured = server.Connected };
                    }
                    endpoint = store.SetEndpoint(JsonArgs.String(args, "endpoint", 2048, true));
                    return new { endpoint };
                }
                finally { management.Release(); }
            case "request":
                var lease = session.Capture();
                if (endpoint == "") throw new NativeFailure("server_unconfigured");
                return await server.Request(endpoint, JsonArgs.String(args, "path", 80), JsonArgs.Object(args, "body"), lease);
            case "executeTool":
                var toolLease = session.Capture();
                var name = JsonArgs.String(args, "name", 80);
                var payload = JsonArgs.Object(args, "args");
                if (!ToolNames.Contains(name, StringComparer.Ordinal)) throw new NativeFailure("invalid_request");
                await tools.WaitAsync(toolLease.Token);
                try
                {
                    toolLease.Check();
                    var result = await automation.Run(() => RunTool(name, payload, toolLease));
                    toolLease.Check();
                    return result;
                }
                finally { tools.Release(); }
            case "heard":
                session.Capture().Check();
                // Transcript never authorizes an OS action and is not persisted here.
                return new { received = true };
            case "declineCall": return new { declined = true };
            default: throw new NativeFailure("invalid_request");
        }
    }

    private object RunTool(string name, JsonElement args, NativeSession.Lease lease)
    {
        lease.Check();
        return name switch
        {
            "device_status" => control.Status(),
            "app_list" => control.AppList(JsonArgs.String(args, "query", 160, true)),
            "app_open" => control.Open(JsonArgs.String(args, "target", 160), lease),
            "screen_read" => control.Read(lease),
            "ui_tap" => control.Tap(JsonArgs.String(args, "nodeId", 160), lease),
            "ui_type" => control.Type(JsonArgs.String(args, "nodeId", 160), JsonArgs.String(args, "text", 4096, true), lease),
            "ui_scroll" => control.Scroll(JsonArgs.String(args, "direction", 8), lease),
            "file_list" => workspace.List(JsonArgs.String(args, "path", 512, true), lease),
            "file_read" => workspace.Read(JsonArgs.String(args, "path", 512), lease),
            "file_write" => workspace.Write(JsonArgs.String(args, "path", 512), JsonArgs.String(args, "content", NativePolicy.MaxFileBytes, true), lease),
            _ => throw new NativeFailure("invalid_request")
        };
    }

    public void Stop() { session.Set(false, session.Mode); control.Invalidate(); }
    public void Dispose() { Stop(); monitor.Cancel(); monitor.Dispose(); server.Dispose(); session.Dispose(); }
}
