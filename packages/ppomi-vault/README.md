# ppomi-vault

Client E2E vault. libsodium XChaCha20-Poly1305 + wrapped DEK. The remote store sees ciphertext only. ADR / PM lock: [`docs/e2e-vault.md`](../../docs/e2e-vault.md).

```ts
import {
  KB_STAR_BIZ_ACCOUNT_KEY,
  ClientVault,
  MemoryCiphertextStore,
  acceptAuthApproval,
  createAuthRequest,
  persistAuthRequest,
  readyVault,
} from "ppomi-vault";

await readyVault();
const store = new MemoryCiphertextStore();
const { vault: mac } = ClientVault.firstDevice("user_stub", store, recoveryPassphrase);
mac.put(KB_STAR_BIZ_ACCOUNT_KEY, digits); // MZZ-47 hook — then drop digits

const win = createAuthRequest("user_stub");
persistAuthRequest(store, win.public); // pubkey + fingerprint + expiry only
const wrapped = mac.approveAuthRequest(win.public, win.public.fingerprint);
const fill = new ClientVault("user_stub", acceptAuthApproval(wrapped, win), store)
  .get(KB_STAR_BIZ_ACCOUNT_KEY); // MZZ-48 hook — fill sink only, never chat
```

`get` is plaintext for the caller. Catalog / `StepResult` evidence is `vaultEvidence` (`****last4` + key).

## Locks

- Server never sees DEK, device private keys, recovery passphrase, or decrypted payloads.
- Server OK: ciphertext, wrapped DEK, KDF salt/verifier, Clerk user id, pairing pubkey/fingerprint/expiry.
- NPKI cert blobs stay in NPKI.
- Pairing is existing-device approve + fingerprint phrase. QR is out of this slice.
- Daily unlock: device private key in OS lock (MZZ-47).

## Tests

```sh
npm --prefix packages/ppomi-vault test
node --experimental-strip-types packages/ppomi-vault/example/src/main.ts
```
