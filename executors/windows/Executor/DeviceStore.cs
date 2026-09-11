using System.Runtime.InteropServices;
using System.Security.AccessControl;
using System.Security.Cryptography;
using System.Security.Principal;
using System.Text.Json;

namespace Ppomi.Executor;

// Everything secret (legacy import, Google session, device private key, unwrapped record key) is a DPAPI blob for the current
// Windows user inside a directory whose ACL admits only that user. The device ID is a plain stable identifier, not a secret.
internal sealed class DeviceStore : IAccountStore
{
    public string DirectoryPath { get; }
    private string CredentialPath => Path.Combine(DirectoryPath, "device.dpapi");
    private string EndpointPath => Path.Combine(DirectoryPath, "endpoint.txt");
    private string SessionPath => Path.Combine(DirectoryPath, "session.dpapi");
    private string DeviceKeyPath => Path.Combine(DirectoryPath, "device-key.dpapi");
    private string RecordKeyPath => Path.Combine(DirectoryPath, "record-key.dpapi");
    private string DeviceIdPath => Path.Combine(DirectoryPath, "device-id.txt");
    private readonly object accountGate = new();
    private Guid? deviceId;

    public DeviceStore()
    {
        DirectoryPath = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Ppomi", "Executor");
        Directory.CreateDirectory(DirectoryPath);
        using var held = WindowsHandles.Open(DirectoryPath, true);
        var current = WindowsIdentity.GetCurrent().User ?? throw new NativeFailure("native_unavailable");
        var acl = new DirectorySecurity();
        acl.SetAccessRuleProtection(true, false);
        acl.SetOwner(current);
        acl.AddAccessRule(new FileSystemAccessRule(current, FileSystemRights.FullControl,
            InheritanceFlags.ContainerInherit | InheritanceFlags.ObjectInherit, PropagationFlags.None, AccessControlType.Allow));
        new DirectoryInfo(DirectoryPath).SetAccessControl(acl);
    }

    public DeviceConfiguration? Load()
    {
        if (!File.Exists(CredentialPath)) return null;
        byte[]? plaintext = null;
        try
        {
            using var held = WindowsHandles.Open(DirectoryPath, true);
            plaintext = Protect(WindowsHandles.ReadFile(CredentialPath, 65536), false);
            return DeviceConfiguration.Decode(plaintext);
        }
        catch { return null; } // Corruption needs user re-import; no stored content is logged.
        finally { if (plaintext != null) CryptographicOperations.ZeroMemory(plaintext); }
    }

    public DeviceConfiguration Import(string path)
    {
        if (!Path.IsPathFullyQualified(path) || path.StartsWith("\\\\", StringComparison.Ordinal)) throw new NativeFailure("invalid_request");
        var bytes = WindowsHandles.ReadFile(Path.GetFullPath(path), 16384);
        try
        {
            var config = DeviceConfiguration.Decode(bytes);
            AtomicWrite(CredentialPath, Protect(bytes, true));
            return config;
        }
        finally { CryptographicOperations.ZeroMemory(bytes); }
    }

    public Guid DeviceId
    {
        get
        {
            lock (accountGate)
            {
                if (deviceId is { } known) return known;
                try
                {
                    using var held = WindowsHandles.Open(DirectoryPath, true);
                    if (Guid.TryParse(NativePolicy.Utf8.GetString(WindowsHandles.ReadFile(DeviceIdPath, 64)).Trim(), out var stored)) return (deviceId = stored).Value;
                }
                catch { /* missing or unreadable: a fresh installation gets a new ID */ }
                var created = Guid.NewGuid();
                AtomicWrite(DeviceIdPath, NativePolicy.Utf8.GetBytes(created.ToString("D")));
                deviceId = created;
                return created;
            }
        }
    }

    public byte[] DevicePrivateKey()
    {
        lock (accountGate)
        {
            var existing = LoadProtected(DeviceKeyPath, 4096);
            if (existing is { Length: X25519.KeySize }) return existing;
            var created = RandomNumberGenerator.GetBytes(X25519.KeySize);
            AtomicWrite(DeviceKeyPath, Protect(created, true));
            return created;
        }
    }

    public GoogleSession? LoadSession()
    {
        var bytes = LoadProtected(SessionPath, 65536);
        try { return bytes == null ? null : GoogleSession.Decode(bytes); }
        finally { if (bytes != null) CryptographicOperations.ZeroMemory(bytes); }
    }
    public void SaveSession(GoogleSession session)
    {
        var bytes = session.Encode();
        try { AtomicWrite(SessionPath, Protect(bytes, true)); }
        finally { CryptographicOperations.ZeroMemory(bytes); }
    }
    public void DeleteSession() => Delete(SessionPath);

    public RecordKey? LoadRecordKey()
    {
        var bytes = LoadProtected(RecordKeyPath, 16384);
        try { return bytes == null ? null : RecordKey.Decode(bytes); }
        finally { if (bytes != null) CryptographicOperations.ZeroMemory(bytes); }
    }
    public void SaveRecordKey(RecordKey key)
    {
        var bytes = key.Encode();
        try { AtomicWrite(RecordKeyPath, Protect(bytes, true)); }
        finally { CryptographicOperations.ZeroMemory(bytes); }
    }
    public void DeleteRecordKey() => Delete(RecordKeyPath);

    private byte[]? LoadProtected(string path, int limit)
    {
        if (!File.Exists(path)) return null;
        try
        {
            using var held = WindowsHandles.Open(DirectoryPath, true);
            return Protect(WindowsHandles.ReadFile(path, limit), false);
        }
        catch { return null; } // Corruption means signing in again; no stored content is logged.
    }

    private void Delete(string path)
    {
        try
        {
            using var held = WindowsHandles.Open(DirectoryPath, true);
            if (File.Exists(path)) File.Delete(path);
        }
        catch { /* an unreadable leftover cannot be decrypted by anyone else; the next save replaces it */ }
    }

    public string LoadEndpoint()
    {
        try
        {
            using var held = WindowsHandles.Open(DirectoryPath, true);
            return NativePolicy.ConfiguredEndpoint(NativePolicy.Utf8.GetString(WindowsHandles.ReadFile(EndpointPath, 2048)));
        }
        catch { return NativePolicy.DefaultAgentEndpoint; }
    }

    public string SetEndpoint(string endpoint)
    {
        var normalized = NativePolicy.ConfiguredEndpoint(endpoint);
        AtomicWrite(EndpointPath, NativePolicy.Utf8.GetBytes(normalized));
        return normalized;
    }

    private void AtomicWrite(string destination, byte[] bytes)
    {
        using var held = WindowsHandles.Open(DirectoryPath, true);
        var temporary = Path.Combine(DirectoryPath, ".ppomi-write-" + Guid.NewGuid().ToString("N"));
        try
        {
            using (var file = new FileStream(temporary, FileMode.CreateNew, FileAccess.Write, FileShare.None, 8192, FileOptions.WriteThrough))
            { file.Write(bytes); file.Flush(true); }
            File.Move(temporary, destination, true);
        }
        finally { if (File.Exists(temporary)) File.Delete(temporary); }
    }

    [StructLayout(LayoutKind.Sequential)] private struct Blob { public int Size; public nint Data; }
    [DllImport("crypt32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool CryptProtectData(ref Blob input, string? description, nint entropy, nint reserved, nint prompt, uint flags, out Blob output);
    [DllImport("crypt32.dll", SetLastError = true)]
    private static extern bool CryptUnprotectData(ref Blob input, nint description, nint entropy, nint reserved, nint prompt, uint flags, out Blob output);
    [DllImport("kernel32.dll")] private static extern nint LocalFree(nint memory);

    private static byte[] Protect(byte[] inputBytes, bool encrypt)
    {
        var pointer = Marshal.AllocHGlobal(inputBytes.Length);
        var input = new Blob { Size = inputBytes.Length, Data = pointer };
        Blob output = default;
        try
        {
            Marshal.Copy(inputBytes, 0, pointer, inputBytes.Length);
            var ok = encrypt ? CryptProtectData(ref input, "Ppomi device", 0, 0, 0, 1, out output)
                : CryptUnprotectData(ref input, 0, 0, 0, 0, 1, out output);
            if (!ok || output.Size is <= 0 or > 65536 || output.Data == 0) throw new NativeFailure("server_auth");
            var result = new byte[output.Size];
            Marshal.Copy(output.Data, result, 0, result.Length);
            return result;
        }
        finally
        {
            // Clear the unmanaged plaintext copies before releasing either allocation.
            Marshal.Copy(new byte[inputBytes.Length], 0, pointer, inputBytes.Length);
            Marshal.FreeHGlobal(pointer);
            if (output.Data != 0)
            {
                if (output.Size is > 0 and <= 65536) Marshal.Copy(new byte[output.Size], 0, output.Data, output.Size);
                LocalFree(output.Data);
            }
        }
    }
}
