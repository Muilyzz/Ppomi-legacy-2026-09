using Microsoft.Win32.SafeHandles;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text;

namespace Ppomi.Executor;

internal static class WindowsHandles
{
    private const uint Read = 0x80000000, Attributes = 0x80, OpenExisting = 3;
    private const uint BackupSemantics = 0x02000000, OpenReparsePoint = 0x00200000;

    [StructLayout(LayoutKind.Sequential)]
    private struct FileInfo
    {
        public uint Attributes;
        public System.Runtime.InteropServices.ComTypes.FILETIME Created, Accessed, Written;
        public uint VolumeSerial, SizeHigh, SizeLow, NumberOfLinks, IndexHigh, IndexLow;
    }
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern SafeFileHandle CreateFileW(string name, uint access, uint share, nint security, uint disposition, uint flags, nint template);
    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool GetFileInformationByHandle(SafeFileHandle handle, out FileInfo info);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern uint GetFinalPathNameByHandleW(SafeFileHandle handle, StringBuilder buffer, uint size, uint flags);

    // No delete sharing: held directories cannot be renamed/replaced while a child operation is active.
    // OPEN_REPARSE_POINT opens the link itself, whose attributes are then rejected.
    public static SafeFileHandle Open(string path, bool directory)
    {
        var handle = CreateFileW(path, directory ? Attributes : Read, directory ? 3u : 1u,
            0, OpenExisting, OpenReparsePoint | BackupSemantics, 0);
        try
        {
            if (handle.IsInvalid || !GetFileInformationByHandle(handle, out var info) ||
                (info.Attributes & (uint)FileAttributes.ReparsePoint) != 0 ||
                ((info.Attributes & (uint)FileAttributes.Directory) != 0) != directory ||
                (!directory && info.NumberOfLinks != 1)) throw new NativeFailure("invalid_request");
            var name = new StringBuilder(32768);
            var length = GetFinalPathNameByHandleW(handle, name, (uint)name.Capacity, 0);
            if (length == 0 || length >= name.Capacity) throw new NativeFailure("invalid_request");
            var final = name.ToString();
            if (final.StartsWith("\\\\?\\UNC\\", StringComparison.OrdinalIgnoreCase)) throw new NativeFailure("invalid_request");
            if (final.StartsWith("\\\\?\\", StringComparison.Ordinal)) final = final[4..];
            if (!string.Equals(Path.GetFullPath(path).TrimEnd('\\'), final.TrimEnd('\\'), StringComparison.OrdinalIgnoreCase))
                throw new NativeFailure("invalid_request");
            return handle;
        }
        catch { handle.Dispose(); throw; }
    }

    public static byte[] ReadFile(string path, int limit)
    {
        using var handle = Open(path, false);
        using var stream = new FileStream(handle, FileAccess.Read);
        if (stream.Length > limit) throw new NativeFailure("invalid_request");
        var bytes = new byte[(int)stream.Length];
        stream.ReadExactly(bytes);
        if (stream.ReadByte() != -1) throw new NativeFailure("invalid_request");
        return bytes;
    }
}

internal sealed class WindowsWorkspace
{
    private readonly string root;
    public WindowsWorkspace(string path)
    {
        root = Path.GetFullPath(path);
        Directory.CreateDirectory(root);
        using var held = WindowsHandles.Open(root, true);
    }

    private sealed class HeldPath : IDisposable
    {
        public List<SafeFileHandle> Handles { get; } = [];
        public required string Path { get; init; }
        public void Dispose() { foreach (var handle in Handles.AsEnumerable().Reverse()) handle.Dispose(); }
    }

    private HeldPath Hold(string path, bool isDirectory)
    {
        var parts = NativePolicy.WorkspaceParts(path, isDirectory);
        var result = new HeldPath { Path = parts.Aggregate(root, Path.Combine) };
        try
        {
            var current = root;
            result.Handles.Add(WindowsHandles.Open(current, true));
            foreach (var part in isDirectory ? parts : parts[..^1])
            {
                current = Path.Combine(current, part);
                result.Handles.Add(WindowsHandles.Open(current, true));
            }
            return result;
        }
        catch { result.Dispose(); throw; }
    }

    public object List(string path, NativeSession.Lease lease)
    {
        lease.Check();
        using var held = Hold(path, true);
        var items = new List<object>();
        var scanned = 0;
        var truncated = false;
        foreach (var entry in Directory.EnumerateFileSystemEntries(held.Path))
        {
            lease.Check();
            if (++scanned > 2000 || items.Count >= 1000) { truncated = true; break; }
            var name = Path.GetFileName(entry);
            try
            {
                NativePolicy.WorkspaceParts(name, false);
                var isDirectory = (File.GetAttributes(entry) & FileAttributes.Directory) != 0;
                using var handle = WindowsHandles.Open(entry, isDirectory);
                long size = 0;
                if (!isDirectory) { using var stream = new FileStream(handle, FileAccess.Read); size = stream.Length; }
                items.Add(new { name, path = path.Length == 0 ? name : path + "/" + name, type = isDirectory ? "directory" : "file", size });
            }
            catch (Exception ex) when (ex is NativeFailure or IOException or UnauthorizedAccessException) { }
        }
        return new { path, entries = items, truncated };
    }

    public object Read(string path, NativeSession.Lease lease)
    {
        lease.Check();
        using var held = Hold(path, false);
        var bytes = WindowsHandles.ReadFile(held.Path, NativePolicy.MaxFileBytes);
        var content = NativePolicy.Utf8.GetString(bytes);
        lease.Check();
        return new { path, content, bytes = bytes.Length, sha256 = Hash(bytes) };
    }

    public object Write(string path, string content, NativeSession.Lease lease)
    {
        lease.Check();
        var bytes = NativePolicy.Utf8.GetBytes(content);
        if (bytes.Length > NativePolicy.MaxFileBytes) throw new NativeFailure("invalid_request");
        using var held = Hold(path, false);
        // Inspect existing entries without following them. Rename below replaces a directory entry,
        // never writes through a potentially raced hard link or junction.
        if (File.Exists(held.Path) || Directory.Exists(held.Path))
        {
            using var existing = WindowsHandles.Open(held.Path, false);
        }
        var temporary = Path.Combine(Path.GetDirectoryName(held.Path)!, ".ppomi-write-" + Guid.NewGuid().ToString("N"));
        try
        {
            using (var stream = new FileStream(temporary, FileMode.CreateNew, FileAccess.Write, FileShare.None, 8192, FileOptions.WriteThrough))
            { stream.Write(bytes); stream.Flush(true); }
            lease.Commit(() => { File.Move(temporary, held.Path, true); return true; });
            var readback = WindowsHandles.ReadFile(held.Path, NativePolicy.MaxFileBytes);
            if (!CryptographicOperations.FixedTimeEquals(bytes, readback)) throw new NativeFailure("tool_failed");
            return new { path, bytes = bytes.Length, sha256 = Hash(bytes), verified = true };
        }
        finally { if (File.Exists(temporary)) File.Delete(temporary); }
    }

    private static string Hash(byte[] bytes) => Convert.ToHexString(SHA256.HashData(bytes)).ToLowerInvariant();
}
