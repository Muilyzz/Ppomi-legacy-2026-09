using System.Numerics;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;

namespace Ppomi.Executor;

/// RFC 7748 X25519 over System.Numerics. .NET 10 ships no Curve25519 agreement, and the executor must not take a NuGet
/// dependency for its trust boundary. BigInteger is not constant-time; the private scalar is a per-installation key that the
/// same Windows user could read from DPAPI anyway, so the local timing surface adds nothing new. Verified with RFC 7748 vectors.
public static class X25519
{
    public const int KeySize = 32;
    private static readonly BigInteger Prime = BigInteger.Pow(2, 255) - 19;
    private static readonly BigInteger A24 = 121665;

    public static byte[] PublicKey(ReadOnlySpan<byte> privateKey)
    {
        var basePoint = new byte[KeySize];
        basePoint[0] = 9;
        return ScalarMult(privateKey, basePoint);
    }

    /// Shared secret. An all-zero output means a low-order peer point; RFC 7748 §6.1 tells callers to reject it.
    public static byte[] ScalarMult(ReadOnlySpan<byte> scalar, ReadOnlySpan<byte> u)
    {
        if (scalar.Length != KeySize || u.Length != KeySize) throw new NativeFailure("invalid_request");
        var k = scalar.ToArray();
        k[0] &= 248; k[31] &= 127; k[31] |= 64;
        var point = u.ToArray();
        point[31] &= 127;
        var x1 = new BigInteger(point, isUnsigned: true, isBigEndian: false);
        var kInt = new BigInteger(k, isUnsigned: true, isBigEndian: false);
        BigInteger x2 = BigInteger.One, z2 = BigInteger.Zero, x3 = x1, z3 = BigInteger.One;
        var swap = BigInteger.Zero;
        for (var t = 254; t >= 0; t--)
        {
            var kt = (kInt >> t) & BigInteger.One;
            swap ^= kt;
            (x2, x3) = Swap(swap, x2, x3);
            (z2, z3) = Swap(swap, z2, z3);
            swap = kt;
            var a = Mod(x2 + z2); var aa = Mod(a * a);
            var b = Mod(x2 - z2); var bb = Mod(b * b);
            var e = Mod(aa - bb);
            var c = Mod(x3 + z3); var d = Mod(x3 - z3);
            var da = Mod(d * a); var cb = Mod(c * b);
            var sum = Mod(da + cb); var difference = Mod(da - cb);
            x3 = Mod(sum * sum);
            z3 = Mod(x1 * Mod(difference * difference));
            x2 = Mod(aa * bb);
            z2 = Mod(e * Mod(aa + Mod(A24 * e)));
        }
        (x2, _) = Swap(swap, x2, x3);
        (z2, _) = Swap(swap, z2, z3);
        var result = Mod(x2 * BigInteger.ModPow(z2, Prime - 2, Prime));
        var bytes = new byte[KeySize];
        if (!result.TryWriteBytes(bytes, out _, isUnsigned: true, isBigEndian: false)) throw new NativeFailure("invalid_request");
        CryptographicOperations.ZeroMemory(k);
        return bytes;
    }

    private static BigInteger Mod(BigInteger value)
    {
        var r = BigInteger.Remainder(value, Prime);
        return r.Sign < 0 ? r + Prime : r;
    }

    /// Arithmetic conditional swap (no data-dependent branch on the scalar bit).
    private static (BigInteger, BigInteger) Swap(BigInteger bit, BigInteger left, BigInteger right)
    {
        var delta = (left - right) * bit;
        return (left - delta, right + delta);
    }
}

/// The record key wrapped for one device, exactly as the Mac's KeyWrap (SharedRecordCrypto.swift) produces it:
/// ppomi-wrap-v1 = ephemeral X25519 public key (32) + AES-GCM nonce (12) + ciphertext (32) + tag (16) = 92 bytes.
public static class KeyWrap
{
    public const string Version = "ppomi-wrap-v1";
    public const int WrappedSize = 32 + 12 + 32 + 16;

    public static byte[] Unwrap(ReadOnlySpan<byte> blob, ReadOnlySpan<byte> privateKey, Guid workspaceId, Guid keyId)
    {
        if (blob.Length != WrappedSize) throw new NativeFailure("response_invalid");
        var recipient = X25519.PublicKey(privateKey);
        var shared = X25519.ScalarMult(privateKey, blob[..32]);
        if (shared.All(b => b == 0)) throw new NativeFailure("response_invalid");
        var symmetric = Derive(shared, workspaceId, keyId);
        var key = new byte[32];
        try
        {
            using var gcm = new AesGcm(symmetric, 16);
            gcm.Decrypt(blob[32..44], blob[44..76], blob[76..92], key, Aad(workspaceId, keyId, recipient));
            return key;
        }
        catch (CryptographicException) { CryptographicOperations.ZeroMemory(key); throw new NativeFailure("response_invalid"); }
        finally { CryptographicOperations.ZeroMemory(shared); CryptographicOperations.ZeroMemory(symmetric); }
    }

    /// Only tests and a future key-holding Windows device wrap; the sign-in path never calls this.
    public static byte[] Wrap(ReadOnlySpan<byte> key, ReadOnlySpan<byte> recipient, Guid workspaceId, Guid keyId)
    {
        if (key.Length != 32 || recipient.Length != 32) throw new NativeFailure("invalid_request");
        var ephemeral = RandomNumberGenerator.GetBytes(32);
        var shared = X25519.ScalarMult(ephemeral, recipient);
        if (shared.All(b => b == 0)) throw new NativeFailure("invalid_request");
        var symmetric = Derive(shared, workspaceId, keyId);
        var output = new byte[WrappedSize];
        try
        {
            X25519.PublicKey(ephemeral).CopyTo(output, 0);
            RandomNumberGenerator.Fill(output.AsSpan(32, 12));
            using var gcm = new AesGcm(symmetric, 16);
            gcm.Encrypt(output.AsSpan(32, 12), key, output.AsSpan(44, 32), output.AsSpan(76, 16), Aad(workspaceId, keyId, recipient));
            return output;
        }
        finally { CryptographicOperations.ZeroMemory(ephemeral); CryptographicOperations.ZeroMemory(shared); CryptographicOperations.ZeroMemory(symmetric); }
    }

    private static byte[] Derive(byte[] shared, Guid workspaceId, Guid keyId) =>
        HKDF.DeriveKey(HashAlgorithmName.SHA256, shared, 32, Encoding.UTF8.GetBytes(Lower(workspaceId)), Encoding.UTF8.GetBytes(Version + "|" + Lower(keyId)));

    private static byte[] Aad(Guid workspaceId, Guid keyId, ReadOnlySpan<byte> recipient)
    {
        var prefix = Encoding.UTF8.GetBytes(Version + "|" + Lower(workspaceId) + "|" + Lower(keyId) + "|");
        var aad = new byte[prefix.Length + recipient.Length];
        prefix.CopyTo(aad, 0);
        recipient.CopyTo(aad.AsSpan(prefix.Length));
        return aad;
    }

    private static string Lower(Guid value) => value.ToString("D").ToLowerInvariant();
}

/// The unwrapped record key of this device, kept only in the DPAPI store. Windows has no records viewer yet; holding the key
/// is what makes this device a full member of the workspace, like the iPad.
public sealed record RecordKey(Guid WorkspaceId, Guid KeyId, byte[] Key, IReadOnlyDictionary<string, Guid> Records)
{
    public byte[] Encode() => JsonSerializer.SerializeToUtf8Bytes(new
    {
        workspaceId = WorkspaceId, keyId = KeyId, key = Convert.ToBase64String(Key),
        records = Records.ToDictionary(pair => pair.Key, pair => pair.Value.ToString("D"))
    });

    public static RecordKey? Decode(ReadOnlyMemory<byte> bytes)
    {
        if (bytes.Length > 16384) return null;
        try
        {
            using var document = JsonDocument.Parse(bytes, new JsonDocumentOptions { MaxDepth = 8 });
            var json = document.RootElement;
            var key = Convert.FromBase64String(JsonArgs.String(json, "key", 64));
            if (key.Length != 32 || !Guid.TryParse(JsonArgs.String(json, "workspaceId", 36), out var workspace) || !Guid.TryParse(JsonArgs.String(json, "keyId", 36), out var keyId)) return null;
            return new RecordKey(workspace, keyId, key, ParseRecords(JsonArgs.Object(json, "records")));
        }
        catch { return null; }
    }

    /// Record name → record ID as the server sends it ({"ledger":"uuid", …}). Names are opaque labels; IDs are the references.
    public static IReadOnlyDictionary<string, Guid> ParseRecords(JsonElement records)
    {
        var result = new Dictionary<string, Guid>(StringComparer.Ordinal);
        foreach (var property in records.EnumerateObject())
        {
            if (property.Name.Length is 0 or > 64 || property.Value.ValueKind != JsonValueKind.String || !Guid.TryParse(property.Value.GetString(), out var id) || result.Count >= 64)
                throw new NativeFailure("response_invalid");
            result[property.Name] = id;
        }
        return result;
    }
}
