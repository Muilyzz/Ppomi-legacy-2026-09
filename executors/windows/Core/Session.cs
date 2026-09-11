namespace Ppomi.Executor;

// Starting/stopping is native UI management, never an executable model tool.
public sealed class NativeSession : IDisposable
{
    private readonly object gate = new();
    private CancellationTokenSource? cancellation;
    private long generation;
    private string mode = "text";
    public bool Active { get { lock (gate) return cancellation != null; } }
    public string Mode { get { lock (gate) return mode; } }

    public void Set(bool active, string selectedMode)
    {
        if (selectedMode is not ("text" or "voice")) throw new NativeFailure("invalid_request");
        lock (gate)
        {
            if (active && cancellation != null) throw new NativeFailure("invalid_request");
            cancellation?.Cancel();
            cancellation?.Dispose();
            cancellation = active ? new CancellationTokenSource() : null;
            mode = selectedMode;
            generation++;
        }
    }

    public Lease Capture()
    {
        lock (gate)
        {
            if (cancellation == null) throw new NativeFailure("session_ended");
            return new Lease(this, generation, cancellation.Token);
        }
    }

    private void Check(long expected)
    {
        lock (gate)
            if (cancellation == null || generation != expected) throw new NativeFailure("session_ended");
    }

    public sealed class Lease(NativeSession owner, long generation, CancellationToken token)
    {
        public CancellationToken Token { get; } = token;
        public void Check() => owner.Check(generation);
        // Admission and a bounded local commit are serialized with Stop. Stop cannot undo an OS action
        // already accepted by another application, but stale queued work can never enter a new session.
        public T Commit<T>(Func<T> operation)
        {
            lock (owner.gate) { Check(); return operation(); }
        }
    }

    public void Dispose() => Set(false, Mode);
}
