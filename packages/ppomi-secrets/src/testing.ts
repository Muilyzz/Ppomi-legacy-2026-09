import {
  assertKey,
  assertValue,
  SecretStoreError,
  type SecretPutOptions,
  type SecretStore,
} from "./store.ts";

/**
 * In-memory test double (`ppomi-secrets/testing`). Not a backend: nothing
 * persists past the process, so never wire it into a runtime.
 */
export class FakeSecretStore implements SecretStore {
  readonly #items = new Map<string, string>();

  put(key: string, value: string, options?: SecretPutOptions): void {
    assertKey(key);
    assertValue(value);
    if (this.#items.has(key) && options?.overwrite !== true) {
      throw new SecretStoreError("exists", `secret already stored for ${key}`);
    }
    this.#items.set(key, value);
  }

  get(key: string): string | undefined {
    assertKey(key);
    return this.#items.get(key);
  }

  delete(key: string): void {
    assertKey(key);
    this.#items.delete(key);
  }
}
