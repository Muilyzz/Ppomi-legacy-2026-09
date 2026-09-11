import { requireExec, scrubDetail } from "./exec.ts";
import {
  assertKey,
  assertValue,
  SecretStoreError,
  type SecretExec,
  type SecretPutOptions,
  type SecretStore,
} from "./store.ts";

/** Same exit codes as the Mac backend so callers see one contract. */
const NOT_FOUND = 44;
const DUPLICATE = 45;

/** Absolute: never resolve the secret-carrying interpreter through PATH. */
function powershellPath(): string {
  const systemRoot = process.env.SystemRoot ?? process.env.windir ?? "C:\\Windows";
  return `${systemRoot}\\System32\\WindowsPowerShell\\v1.0\\powershell.exe`;
}

/**
 * Credential Manager via powershell.exe + advapi32 CredWrite/CredRead/CredDelete.
 * Secret travels in the child env only (`PPOMI_SECRET_VALUE`), never in -Command text.
 * Without `PPOMI_SECRET_OVERWRITE=1` a `put` onto an existing target exits 45
 * (CredWrite itself always replaces; the CredRead probe closes that gap).
 */
const CRED_SCRIPT = `
Add-Type @"
using System;
using System.Runtime.InteropServices;
using System.Text;
public static class PpomiCred {
  [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
  private struct CREDENTIAL {
    public uint Flags;
    public uint Type;
    public string TargetName;
    public string Comment;
    public long LastWritten;
    public uint CredentialBlobSize;
    public IntPtr CredentialBlob;
    public uint Persist;
    public uint AttributeCount;
    public IntPtr Attributes;
    public string TargetAlias;
    public string UserName;
  }
  [DllImport("advapi32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
  private static extern bool CredWrite(ref CREDENTIAL userCredential, uint flags);
  [DllImport("advapi32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
  private static extern bool CredRead(string target, uint type, uint reservedFlag, out IntPtr credentialPtr);
  [DllImport("advapi32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
  private static extern bool CredDelete(string target, uint type, uint flags);
  [DllImport("advapi32.dll")]
  private static extern void CredFree(IntPtr cred);
  public static int Put(string key, string value) {
    byte[] bytes = Encoding.UTF8.GetBytes(value);
    IntPtr ptr = Marshal.AllocHGlobal(bytes.Length);
    try {
      Marshal.Copy(bytes, 0, ptr, bytes.Length);
      CREDENTIAL cred = new CREDENTIAL();
      cred.Type = 1;
      cred.TargetName = key;
      cred.UserName = "ppomi";
      cred.CredentialBlobSize = (uint)bytes.Length;
      cred.CredentialBlob = ptr;
      cred.Persist = 2;
      return CredWrite(ref cred, 0) ? 0 : Marshal.GetLastWin32Error();
    } finally { Marshal.FreeHGlobal(ptr); }
  }
  public static int Get(string key, out string value) {
    value = "";
    IntPtr ptr;
    if (!CredRead(key, 1, 0, out ptr)) return Marshal.GetLastWin32Error();
    try {
      CREDENTIAL cred = (CREDENTIAL)Marshal.PtrToStructure(ptr, typeof(CREDENTIAL));
      byte[] bytes = new byte[cred.CredentialBlobSize];
      if (bytes.Length > 0) Marshal.Copy(cred.CredentialBlob, bytes, 0, bytes.Length);
      value = Encoding.UTF8.GetString(bytes);
      return 0;
    } finally { CredFree(ptr); }
  }
  public static int Exists(string key) {
    IntPtr ptr;
    if (!CredRead(key, 1, 0, out ptr)) return Marshal.GetLastWin32Error();
    CredFree(ptr);
    return 0;
  }
  public static int Delete(string key) {
    if (CredDelete(key, 1, 0)) return 0;
    int err = Marshal.GetLastWin32Error();
    return err == 1168 ? 0 : err;
  }
}
"@
$ErrorActionPreference = 'Stop'
$op = $env:PPOMI_SECRET_OP
$key = $env:PPOMI_SECRET_KEY
if ($op -eq 'put') {
  if ($env:PPOMI_SECRET_OVERWRITE -ne '1') {
    $probe = [PpomiCred]::Exists($key)
    if ($probe -eq 0) { exit 45 }
    if ($probe -ne 1168) { exit $probe }
  }
  $code = [PpomiCred]::Put($key, $env:PPOMI_SECRET_VALUE)
  if ($code -ne 0) { exit $code }
} elseif ($op -eq 'get') {
  $value = $null
  $code = [PpomiCred]::Get($key, [ref]$value)
  if ($code -eq 1168) { exit 44 }
  if ($code -ne 0) { exit $code }
  [Console]::Out.Write($value)
} elseif ($op -eq 'delete') {
  $code = [PpomiCred]::Delete($key)
  if ($code -ne 0) { exit $code }
} else { throw 'bad op' }
`.trim();

function encodedCommand(): string {
  return Buffer.from(CRED_SCRIPT, "utf16le").toString("base64");
}

/** Windows Credential Manager. */
export class CredentialManagerSecretStore implements SecretStore {
  readonly #exec: SecretExec;

  constructor(exec?: SecretExec) {
    this.#exec = requireExec(exec);
  }

  put(key: string, value: string, options?: SecretPutOptions): void {
    assertKey(key);
    assertValue(value);
    const result = this.#run("put", key, value, options?.overwrite === true);
    if (result.status === 0) return;
    if (result.status === DUPLICATE) {
      throw new SecretStoreError("exists", `credential already exists for ${key}`);
    }
    throw new SecretStoreError("failed", `credential put failed ${scrubDetail(result.stderr, value)}`);
  }

  get(key: string): string | undefined {
    assertKey(key);
    const result = this.#run("get", key);
    if (result.status === NOT_FOUND) return undefined;
    if (result.status !== 0) {
      throw new SecretStoreError("failed", `credential get failed ${scrubDetail(result.stderr)}`);
    }
    return result.stdout.length === 0 ? undefined : result.stdout;
  }

  delete(key: string): void {
    assertKey(key);
    const result = this.#run("delete", key);
    if (result.status === 0 || result.status === NOT_FOUND) return;
    throw new SecretStoreError("failed", `credential delete failed ${scrubDetail(result.stderr)}`);
  }

  #run(op: "put" | "get" | "delete", key: string, value?: string, overwrite = false) {
    const extraEnv: Record<string, string> = {
      PPOMI_SECRET_OP: op,
      PPOMI_SECRET_KEY: key,
      // Always set, so an inherited PPOMI_SECRET_OVERWRITE in the parent env cannot flip the guard.
      PPOMI_SECRET_OVERWRITE: overwrite ? "1" : "0",
    };
    if (value !== undefined) extraEnv.PPOMI_SECRET_VALUE = value;
    return this.#exec(
      powershellPath(),
      ["-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-EncodedCommand", encodedCommand()],
      { extraEnv },
    );
  }
}
