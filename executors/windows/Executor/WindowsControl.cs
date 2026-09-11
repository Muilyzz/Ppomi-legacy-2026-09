using System.Collections.Concurrent;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text;
using System.Windows.Automation;

namespace Ppomi.Executor;

internal sealed record RunningApp(string Label, string PackageName, nint Window, int Pid, long Started);
internal sealed record ScreenNode(string id, string? parentId, string text, string role, bool clickable, bool editable,
    bool visible, bool enabled, bool password, object bounds);
internal sealed record ElementState(AutomationElement Element, string Fingerprint, int Pid, bool Protected);
internal sealed record ScreenSnapshot(string Id, RunningApp App, long Timestamp, Dictionary<string, ElementState> Elements, NativeSession.Lease Lease);

internal sealed class WindowsControl
{
    private readonly int ownerPid;
    private readonly HashSet<string> allowed = new(StringComparer.Ordinal);
    private ScreenSnapshot? snapshot;
    private readonly object allowGate = new();

    public WindowsControl(int ownerPid) { this.ownerPid = ownerPid; }
    public void Invalidate() => Interlocked.Exchange(ref snapshot, null);

    public object[] AvailableApps() => Apps().Select(app => (object)new
    { label = app.Label, packageName = app.PackageName, allowed = Allowed(app.PackageName) }).ToArray();
    public object[] ControlApps() => Apps().Where(app => Allowed(app.PackageName)).Select(app => (object)new
    { label = app.Label, packageName = app.PackageName }).ToArray();

    public object AppList(string query)
    {
        if (query.Length > 160) throw new NativeFailure("invalid_request");
        var apps = Apps().Where(app => app.Label.Contains(query, StringComparison.OrdinalIgnoreCase) ||
            app.PackageName.Contains(query, StringComparison.OrdinalIgnoreCase)).ToArray();
        return new { apps = apps.Take(200).Select(app => new { label = app.Label, packageName = app.PackageName, allowed = Allowed(app.PackageName) }), truncated = apps.Length > 200 };
    }

    public void SetAllowed(string[] ids)
    {
        if (ids.Length > 100 || ids.Distinct(StringComparer.Ordinal).Count() != ids.Length) throw new NativeFailure("invalid_request");
        var available = Apps().Select(app => app.PackageName).ToHashSet(StringComparer.Ordinal);
        if (ids.Any(id => !available.Contains(id))) throw new NativeFailure("app_not_found");
        lock (allowGate) { allowed.Clear(); allowed.UnionWith(ids); }
        Invalidate();
    }

    private bool Allowed(string id) { lock (allowGate) return allowed.Contains(id); }

    public object Status()
    {
        var window = GetForegroundWindow();
        GetWindowThreadProcessId(window, out var pid);
        var foreground = Apps().FirstOrDefault(app => app.Window == window);
        return new { platform = "windows", deviceLabel = "Windows", accessibility = true,
            interactiveDesktop = OnInputDesktop(), foregroundApp = foreground == null ? null : new
            { label = foreground.Label, packageName = foreground.PackageName, allowed = Allowed(foreground.PackageName) },
            ownWindow = pid == ownerPid || pid == Environment.ProcessId };
    }

    public object Open(string target, NativeSession.Lease lease)
    {
        var apps = Apps();
        var exact = apps.Where(app => app.PackageName == target).ToArray();
        var choices = exact.Length > 0 ? exact : apps.Where(app => app.Label.Equals(target, StringComparison.OrdinalIgnoreCase)).ToArray();
        if (choices.Length == 0) throw new NativeFailure("app_not_found");
        if (choices.Length != 1) throw new NativeFailure("app_ambiguous");
        var app = choices[0];
        RequireAllowed(app);
        lease.Check();
        Invalidate();
        // Foreground activation only. Never ShellExecute, Process.Start, or launch an arbitrary path.
        ShowWindowAsync(app.Window, 9);
        if (!SetForegroundWindow(app.Window)) throw new NativeFailure("tool_failed");
        lease.Check();
        return new { packageName = app.PackageName, activated = GetForegroundWindow() == app.Window };
    }

    public object Read(NativeSession.Lease lease)
    {
        lease.Check();
        Invalidate();
        var app = Foreground();
        var root = AutomationElement.FromHandle(app.Window);
        var id = Guid.NewGuid().ToString("N");
        var elements = new Dictionary<string, ElementState>(StringComparer.Ordinal);
        var nodes = new List<ScreenNode>();
        var queue = new Queue<(AutomationElement Element, string? Parent, int Depth)>();
        queue.Enqueue((root, null, 0));
        var seen = 0;
        var started = Stopwatch.GetTimestamp();
        var truncated = false;
        while (queue.Count != 0)
        {
            lease.Check();
            if (nodes.Count >= 500 || ++seen > 1000 || Stopwatch.GetElapsedTime(started).TotalSeconds > 5) { truncated = true; break; }
            var (element, parent, depth) = queue.Dequeue();
            try
            {
                var info = element.Current;
                if (info.ProcessId != app.Pid || info.IsOffscreen) continue;
                var nodeId = id + ":" + nodes.Count;
                var protect = (parent != null && elements.TryGetValue(parent, out var parentState) && parentState.Protected) ||
                    info.IsPassword || NativePolicy.ProtectedLabel(info.Name) || NativePolicy.ProtectedLabel(info.AutomationId);
                var name = info.IsPassword ? "[protected]" : Limit(info.Name, 1024);
                var value = "";
                var editable = element.TryGetCurrentPattern(ValuePattern.Pattern, out var valueObject) && !((ValuePattern)valueObject).Current.IsReadOnly;
                // Never request a password value, even if a provider implements ValuePattern for it.
                if (!info.IsPassword && valueObject is ValuePattern valuePattern) value = Limit(valuePattern.Current.Value, 2048);
                if (!info.IsPassword && value.Length == 0 && info.ControlType == ControlType.Document &&
                    element.TryGetCurrentPattern(TextPattern.Pattern, out var textObject))
                    value = ((TextPattern)textObject).DocumentRange.GetText(2048);
                var text = value.Length > 0 && value != name ? name + " " + value : name;
                var invoke = element.TryGetCurrentPattern(InvokePattern.Pattern, out _);
                var rect = info.BoundingRectangle;
                var state = Fingerprint(element);
                elements[nodeId] = new(element, state, info.ProcessId, protect);
                nodes.Add(new(nodeId, parent, text, info.ControlType.ProgrammaticName,
                    invoke && !protect && info.IsEnabled, editable && !protect && info.IsEnabled,
                    true, info.IsEnabled, info.IsPassword,
                    new { left = Finite(rect.Left), top = Finite(rect.Top), right = Finite(rect.Right), bottom = Finite(rect.Bottom) }));
                if (depth >= 20 || info.IsPassword) continue;
                var child = TreeWalker.ControlViewWalker.GetFirstChild(element);
                var count = 0;
                while (child != null && count++ < 500 && queue.Count < 1000)
                {
                    queue.Enqueue((child, nodeId, depth + 1));
                    child = TreeWalker.ControlViewWalker.GetNextSibling(child);
                }
                if (child != null) truncated = true;
            }
            catch (ElementNotAvailableException) { truncated = true; }
        }
        lease.Check();
        if (GetForegroundWindow() != app.Window) throw new NativeFailure("stale_screen");
        snapshot = new(id, app, Stopwatch.GetTimestamp(), elements, lease);
        return new { snapshotId = id, packageName = app.PackageName, appLabel = app.Label, nodes, truncated };
    }

    public object Tap(string nodeId, NativeSession.Lease lease)
    {
        var (_, state) = Current(nodeId, lease);
        if (!state.Element.TryGetCurrentPattern(InvokePattern.Pattern, out var pattern)) throw new NativeFailure("protected_action");
        lease.Check();
        Invalidate();
        ((InvokePattern)pattern).Invoke();
        lease.Check();
        return new { invoked = true, requiresScreenRead = true };
    }

    public object Type(string nodeId, string text, NativeSession.Lease lease)
    {
        if (text.Length > 4096 || text.Any(c => char.IsControl(c) && c != '\t')) throw new NativeFailure("protected_action");
        var (_, state) = Current(nodeId, lease);
        if (!state.Element.TryGetCurrentPattern(ValuePattern.Pattern, out var pattern) || ((ValuePattern)pattern).Current.IsReadOnly)
            throw new NativeFailure("protected_action");
        lease.Check();
        Invalidate();
        ((ValuePattern)pattern).SetValue(text);
        lease.Check();
        return new { typed = true, requiresScreenRead = true };
    }

    public object Scroll(string direction, NativeSession.Lease lease)
    {
        if (direction is not ("up" or "down")) throw new NativeFailure("invalid_request");
        var current = snapshot ?? throw new NativeFailure("stale_screen");
        CheckSnapshot(current, lease);
        var candidates = current.Elements.Where(pair => !pair.Value.Protected &&
            pair.Value.Element.TryGetCurrentPattern(ScrollPattern.Pattern, out var p) && ((ScrollPattern)p).Current.VerticallyScrollable).ToArray();
        if (candidates.Length != 1) throw new NativeFailure("protected_action");
        var (_, state) = Current(candidates[0].Key, lease);
        var pattern = (ScrollPattern)state.Element.GetCurrentPattern(ScrollPattern.Pattern);
        lease.Check();
        Invalidate();
        pattern.Scroll(ScrollAmount.NoAmount, direction == "up" ? ScrollAmount.LargeDecrement : ScrollAmount.LargeIncrement);
        lease.Check();
        return Read(lease);
    }

    private (ScreenSnapshot, ElementState) Current(string nodeId, NativeSession.Lease lease)
    {
        var current = snapshot ?? throw new NativeFailure("stale_screen");
        CheckSnapshot(current, lease);
        if (!current.Elements.TryGetValue(nodeId, out var state) || state.Pid != current.App.Pid ||
            !string.Equals(state.Fingerprint, Fingerprint(state.Element), StringComparison.Ordinal)) throw new NativeFailure("stale_screen");
        var info = state.Element.Current;
        if (state.Protected || info.IsPassword || !info.IsEnabled || info.IsOffscreen ||
            NativePolicy.ProtectedLabel(info.Name) || NativePolicy.ProtectedLabel(info.AutomationId)) throw new NativeFailure("protected_action");
        // A descendant can be moved by the provider. Check current ancestry still reaches this exact window.
        var ancestor = state.Element;
        var belongs = false;
        for (var i = 0; i < 24 && ancestor != null; i++)
        {
            var ancestorInfo = ancestor.Current;
            if (ancestorInfo.IsPassword || NativePolicy.ProtectedLabel(ancestorInfo.Name) || NativePolicy.ProtectedLabel(ancestorInfo.AutomationId))
                throw new NativeFailure("protected_action");
            if (ancestor.Current.NativeWindowHandle == current.App.Window && ancestor.Current.ProcessId == current.App.Pid) { belongs = true; break; }
            ancestor = TreeWalker.ControlViewWalker.GetParent(ancestor);
        }
        if (!belongs) throw new NativeFailure("stale_screen");
        CheckSnapshot(current, lease);
        return (current, state);
    }

    private void CheckSnapshot(ScreenSnapshot current, NativeSession.Lease lease)
    {
        lease.Check();
        current.Lease.Check();
        if (!ReferenceEquals(snapshot, current) || Stopwatch.GetElapsedTime(current.Timestamp) > TimeSpan.FromSeconds(15) ||
            GetForegroundWindow() != current.App.Window) throw new NativeFailure("stale_screen");
        RequireAllowed(current.App);
    }

    private static string Fingerprint(AutomationElement element)
    {
        var info = element.Current;
        var value = !info.IsPassword && element.TryGetCurrentPattern(ValuePattern.Pattern, out var pattern) ? ((ValuePattern)pattern).Current.Value : "";
        var input = string.Join("\u001f", string.Join(',', element.GetRuntimeId()), info.ProcessId,
            info.Name, info.AutomationId, info.ControlType.Id, info.IsPassword, info.IsEnabled, info.IsOffscreen,
            info.BoundingRectangle.ToString(System.Globalization.CultureInfo.InvariantCulture), Limit(value, 8192));
        return Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(input)));
    }

    private RunningApp Foreground()
    {
        if (!OnInputDesktop()) throw new NativeFailure("no_active_screen");
        var app = Apps().FirstOrDefault(app => app.Window == GetForegroundWindow()) ?? throw new NativeFailure("no_active_screen");
        RequireAllowed(app);
        return app;
    }

    private void RequireAllowed(RunningApp app)
    {
        if (!OnInputDesktop()) throw new NativeFailure("no_active_screen");
        if (!Allowed(app.PackageName)) throw new NativeFailure("app_not_allowed");
        if (!Apps().Any(a => a.PackageName == app.PackageName && a.Window == app.Window)) throw new NativeFailure("stale_screen");
    }

    private RunningApp[] Apps()
    {
        var result = new List<RunningApp>();
        var pids = new HashSet<int>();
        EnumWindows((window, _) =>
        {
            if (result.Count >= 250 || !IsWindowVisible(window) || GetWindow(window, 4) != 0) return true;
            GetWindowThreadProcessId(window, out var rawPid);
            var pid = (int)rawPid;
            if (pid <= 0 || pid == ownerPid || pid == Environment.ProcessId || pids.Contains(pid)) return true;
            try
            {
                using var process = Process.GetProcessById(pid);
                if (process.SessionId != Process.GetCurrentProcess().SessionId || IsElevated(process.Handle)) return true;
                var executable = process.MainModule?.FileName;
                if (executable == null || NativePolicy.IsCommandHost(Path.GetFileName(executable)) ||
                    Path.GetFileName(executable).Contains("ppomi", StringComparison.OrdinalIgnoreCase) ||
                    new[] { "msedgewebview2.exe", "ApplicationFrameHost.exe", "ShellExperienceHost.exe", "StartMenuExperienceHost.exe", "SearchHost.exe", "CredentialUIBroker.exe", "consent.exe", "LockApp.exe", "LogonUI.exe" }.Contains(Path.GetFileName(executable), StringComparer.OrdinalIgnoreCase)) return true;
                var started = process.StartTime.ToUniversalTime().Ticks;
                result.Add(new(Limit(process.ProcessName, 120), $"win:{pid}:{started}", window, pid, started));
                pids.Add(pid);
            }
            catch (Exception ex) when (ex is System.ComponentModel.Win32Exception or InvalidOperationException or NotSupportedException) { }
            return true;
        }, 0);
        return result.ToArray();
    }

    public static bool IsElevated(nint process)
    {
        if (!OpenProcessToken(process, 8, out var token)) return true;
        try { return !GetTokenInformation(token, 20, out var elevated, sizeof(int), out _) || elevated != 0; }
        finally { CloseHandle(token); }
    }

    private static bool OnInputDesktop()
    {
        var desktop = OpenInputDesktop(0, false, 0x0001);
        if (desktop == 0) return false;
        try
        {
            var name = new StringBuilder(256);
            return GetUserObjectInformationW(desktop, 2, name, name.Capacity * 2, out _) && name.ToString().Equals("Default", StringComparison.OrdinalIgnoreCase);
        }
        finally { CloseDesktop(desktop); }
    }

    private static string Limit(string? text, int length) => text == null ? "" : text[..Math.Min(text.Length, length)];
    private static double Finite(double value) => double.IsFinite(value) ? value : 0;
    private delegate bool EnumWindow(nint window, nint data);
    [DllImport("user32.dll")] private static extern bool EnumWindows(EnumWindow callback, nint data);
    [DllImport("user32.dll")] private static extern bool IsWindowVisible(nint window);
    [DllImport("user32.dll")] private static extern nint GetWindow(nint window, uint command);
    [DllImport("user32.dll")] private static extern nint GetForegroundWindow();
    [DllImport("user32.dll")] private static extern uint GetWindowThreadProcessId(nint window, out uint pid);
    [DllImport("user32.dll")] private static extern bool SetForegroundWindow(nint window);
    [DllImport("user32.dll")] private static extern bool ShowWindowAsync(nint window, int command);
    [DllImport("user32.dll", SetLastError = true)] private static extern nint OpenInputDesktop(uint flags, bool inherit, uint access);
    [DllImport("user32.dll")] private static extern bool CloseDesktop(nint desktop);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] private static extern bool GetUserObjectInformationW(nint handle, int index, StringBuilder information, int length, out int needed);
    [DllImport("advapi32.dll")] private static extern bool OpenProcessToken(nint process, uint access, out nint token);
    [DllImport("advapi32.dll")] private static extern bool GetTokenInformation(nint token, int type, out int value, int size, out int returned);
    [DllImport("kernel32.dll")] private static extern bool CloseHandle(nint handle);
}

// All UIA objects stay on one MTA thread. A hung provider terminates the helper instead of
// allowing a timed-out action or queued mutation to wake up and run much later.
internal sealed class AutomationWorker
{
    private readonly BlockingCollection<Action> work = new(32);
    public AutomationWorker()
    {
        var thread = new Thread(() => { foreach (var action in work.GetConsumingEnumerable()) action(); })
        { IsBackground = true, Name = "Ppomi UI Automation" };
        thread.SetApartmentState(ApartmentState.MTA);
        thread.Start();
    }

    public async Task<T> Run<T>(Func<T> action)
    {
        var completion = new TaskCompletionSource<T>(TaskCreationOptions.RunContinuationsAsynchronously);
        if (!work.TryAdd(() => { try { completion.TrySetResult(action()); } catch (Exception ex) { completion.TrySetException(ex); } }))
            throw new NativeFailure("tool_failed");
        try { return await completion.Task.WaitAsync(TimeSpan.FromSeconds(20)); }
        catch (TimeoutException) { Environment.Exit(70); throw new NativeFailure("native_unavailable"); }
    }
}
