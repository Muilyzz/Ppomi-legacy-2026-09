import { KeychainSecretStore } from "./darwin.ts";
import { SecretStoreError, type SecretExec, type SecretStore } from "./store.ts";
import { CredentialManagerSecretStore } from "./win32.ts";

/** Live OS backend. Linux has none; tests use `FakeSecretStore` from `ppomi-secrets/testing`. */
export function openOsSecretStore(exec?: SecretExec): SecretStore {
  switch (process.platform) {
    case "darwin":
      return new KeychainSecretStore(exec);
    case "win32":
      return new CredentialManagerSecretStore(exec);
    default:
      throw new SecretStoreError("unavailable", `no OS secret store on ${process.platform}`);
  }
}
