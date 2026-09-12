import { requireExec, scrubDetail } from "./exec.ts";
import {
  assertKey,
  assertValue,
  SecretStoreError,
  type SecretExec,
  type SecretPutOptions,
  type SecretStore,
} from "./store.ts";

/** Absolute: a `security` shim earlier on PATH (e.g. a user-writable Homebrew bin) would receive the value. */
const SECURITY = "/usr/bin/security";
const ACCOUNT = "ppomi";
/** `security` exits with the OSStatus low byte: errSecItemNotFound -25300 → 44, errSecDuplicateItem -25299 → 45. */
const NOT_FOUND = 44;
const DUPLICATE = 45;

/**
 * macOS Keychain via `/usr/bin/security`. Live path for MZZ-47.
 *
 * `put` runs `security -i` and writes the `add-generic-password` line to stdin
 * with the value as `-X <hex>`, so the plaintext is never in argv (visible to
 * `ps`, process telemetry and EDR command-line logs). `-i` shows no prompt when
 * stdin is a pipe, exits with the command's status, and drops a line that does
 * not end in "\n". Never add `-v`: it echoes the parsed arguments to stderr.
 *
 * The item's ACL trusts its creator, `/usr/bin/security`: any process running as
 * the same macOS user can read it back with `find-generic-password -w` without a
 * prompt. Protection is at rest and against other users, not per process.
 */
export class KeychainSecretStore implements SecretStore {
  readonly #exec: SecretExec;

  constructor(exec?: SecretExec) {
    this.#exec = requireExec(exec);
  }

  put(key: string, value: string, options?: SecretPutOptions): void {
    assertKey(key);
    assertValue(value);
    const hex = Buffer.from(value, "utf8").toString("hex");
    const words = ["add-generic-password", "-a", ACCOUNT, "-s", key, "-l", key, "-X", hex];
    if (options?.overwrite === true) words.push("-U");
    const result = this.#exec(SECURITY, ["-i"], { input: `${words.join(" ")}\n` });
    if (result.status === 0) return;
    if (result.status === DUPLICATE) {
      throw new SecretStoreError("exists", `keychain item already exists for ${key}`);
    }
    throw new SecretStoreError("failed", `keychain put failed ${scrubDetail(result.stderr, value, hex)}`);
  }

  get(key: string): string | undefined {
    assertKey(key);
    const result = this.#exec(SECURITY, ["find-generic-password", "-a", ACCOUNT, "-s", key, "-w"]);
    if (result.status === NOT_FOUND) return undefined;
    if (result.status !== 0) {
      throw new SecretStoreError("failed", `keychain get failed ${scrubDetail(result.stderr)}`);
    }
    const value = result.stdout.replace(/\n$/, "");
    return value.length === 0 ? undefined : value;
  }

  delete(key: string): void {
    assertKey(key);
    const result = this.#exec(SECURITY, ["delete-generic-password", "-a", ACCOUNT, "-s", key]);
    if (result.status === 0 || result.status === NOT_FOUND) return;
    throw new SecretStoreError("failed", `keychain delete failed ${scrubDetail(result.stderr)}`);
  }
}
