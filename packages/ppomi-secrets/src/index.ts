export { CredentialManagerSecretStore } from "./win32.ts";
export { defaultSecretExec } from "./exec.ts";
export { KeychainSecretStore } from "./darwin.ts";
export { openOsSecretStore } from "./platform.ts";
export {
  FakeSecretStore,
  KB_STAR_BIZ_ACCOUNT_KEY,
  SecretStoreError,
  assertKey,
  assertValue,
  secretEvidence,
  storeKbStarBizAccount,
  type AccountHandoff,
  type SecretEvidence,
  type SecretExec,
  type SecretExecResult,
  type SecretStore,
  type SecretStoreCode,
} from "./store.ts";
