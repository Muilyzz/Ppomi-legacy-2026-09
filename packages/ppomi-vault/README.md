# ppomi-vault

Client E2E vault for bank/evidence payloads. The remote store sees ciphertext only. ADR: [`docs/e2e-vault.md`](../../docs/e2e-vault.md).

```ts
import {
  KB_STAR_BIZ_ACCOUNT_KEY,
  ClientVault,
  MemoryCiphertextStore,
  acceptDeviceApproval,
  createDeviceKeyPair,
  createVaultKey,
} from "ppomi-vault";

const store = new MemoryCiphertextStore(); // stand-in; a server must accept the same envelope
const mac = new ClientVault("user_stub", createVaultKey(), store);
mac.put(KB_STAR_BIZ_ACCOUNT_KEY, digits); // MZZ-47 hook — then drop digits

const winDevice = createDeviceKeyPair();
const winKey = acceptDeviceApproval(mac.approveDevice(winDevice.publicKey), winDevice, "user_stub");
const win = new ClientVault("user_stub", winKey, store);
const fill = win.get(KB_STAR_BIZ_ACCOUNT_KEY); // MZZ-48 hook — fill sink only, never chat
```

`get` is plaintext for the caller. Catalog / `StepResult` evidence is `vaultEvidence` (`****last4` + key).

## Locks

- Server / `MemoryCiphertextStore` stores `{ v, identityId, id, box }` only. No plaintext column, no vault master key.
- Account/meta may stay Clerk + server-key. Identity here is a stub string.
- NPKI cert blobs stay in NPKI. This package is not a cert store.
- Multi-device: first device `createVaultKey`; second device **existing-device approve** (`approveDevice` / `acceptDeviceApproval`). QR later ships the same wrap blob.
- Daily unlock: keep the vault key in OS lock (MZZ-47 `ppomi-secrets` / Keychain / CredMan). Face ID unlocks that item.

## Tests

```sh
npm --prefix packages/ppomi-vault test
node --experimental-strip-types packages/ppomi-vault/example/src/main.ts
```
