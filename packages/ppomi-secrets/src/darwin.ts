import { requireExec, scrubDetail } from "./exec.ts";
import {
  assertKey,
  assertValue,
  SecretStoreError,
  type SecretExec,
  type SecretStore,
} from "./store.ts";

const ACCOUNT = "ppomi";
const NOT_FOUND = 44;

/** macOS Keychain via `/usr/bin/security`. Live path for MZZ-47. */
export class KeychainSecretStore implements SecretStore {
  readonly #exec: SecretExec;

  constructor(exec?: SecretExec) {
    this.#exec = requireExec(exec);
  }

  put(key: string, value: string): void {
    assertKey(key);
    assertValue(value);
    const result = this.#exec("security", [
      "add-generic-password",
      "-a",
      ACCOUNT,
      "-s",
      key,
      "-l",
      key,
      "-w",
      value,
      "-U",
    ]);
    if (result.status === 0) return;
    throw new SecretStoreError("failed", `keychain put failed ${scrubDetail(result.stderr, value)}`);
  }

  get(key: string): string | undefined {
    assertKey(key);
    const result = this.#exec("security", ["find-generic-password", "-a", ACCOUNT, "-s", key, "-w"]);
    if (result.status === NOT_FOUND) return undefined;
    if (result.status !== 0) {
      throw new SecretStoreError("failed", `keychain get failed ${scrubDetail(result.stderr)}`);
    }
    const value = result.stdout.replace(/\n$/, "");
    return value.length === 0 ? undefined : value;
  }

  delete(key: string): void {
    assertKey(key);
    const result = this.#exec("security", ["delete-generic-password", "-a", ACCOUNT, "-s", key]);
    if (result.status === 0 || result.status === NOT_FOUND) return;
    throw new SecretStoreError("failed", `keychain delete failed ${scrubDetail(result.stderr)}`);
  }
}
