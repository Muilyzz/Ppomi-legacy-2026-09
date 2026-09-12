# ppomi-vault

Client E2E vault. libsodium XChaCha20-Poly1305 on a random DEK; DEK wrapped to devices with an authenticated `crypto_box_easy` and to a recovery passphrase with Argon2id. The remote store sees ciphertext, wrapped DEKs, KDF parameters and pairing public keys only. ADR / PM lock: [`docs/e2e-vault.md`](../../docs/e2e-vault.md).

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
const { vault: mac, device: macDevice } = ClientVault.firstDevice("user_stub", store, recoveryPassphrase); // Argon2id MODERATE
mac.put(KB_STAR_BIZ_ACCOUNT_KEY, digits); // MZZ-47 hook — then drop digits

// Win: publish pubkey + expiry; show win.fingerprint on the Win screen.
const win = createAuthRequest("user_stub");
persistAuthRequest(store, win.public);

// Mac: the person reads the phrase off the Win screen. Never pass anything the store relayed here.
const wrapped = mac.approveAuthRequest(relayedRequest, phraseTypedFromWinScreen);
// Mac screen shows mac.deviceFingerprint().

// Win: the person reads the Mac's phrase; a wrap from any other key is refused before it is opened.
const dek = acceptAuthApproval(wrapped, win, phraseTypedFromMacScreen);
const fill = new ClientVault("user_stub", dek, store).get(KB_STAR_BIZ_ACCOUNT_KEY); // MZZ-48 hook — fill sink only
```

`get` is plaintext for the caller. Catalog / `StepResult` evidence is `vaultEvidence` (`****last4` + key).

## Locks

- Server never sees the DEK, device private keys, the recovery passphrase, a fingerprint phrase, or decrypted payloads.
- Server OK: `payload` (`seq` + `box`), `dek-device` (authenticated wrap), `dek-recovery` (`box`, `salt`, `verifier`, `kdf`), `pair-request` (`publicKey`, `expiresAt`), Clerk user id.
- Pairing is existing-device approve with **two** out-of-band phrases: the new device's (gates the approval) and the approver's (gates accepting the wrap). QR is out of this slice.
- Daily unlock: device private key in OS lock (MZZ-47); `openDeviceDek` opens this device's own wrap (`ppomi/vault/dek/device/<fingerprint>`).
- `ppomi/vault/` is reserved for vault records; payload `put`/`get`/`delete` refuse it.
- Recovery: Argon2id defaults to `MODERATE`; anything below `INTERACTIVE` is refused on wrap, on open, and by the mock store. Parameters are stored with the record.
- NPKI cert blobs stay in NPKI.

## What the store can and cannot do

- **Cannot** read payloads, swap an envelope between key ids or identities (AAD), or re-label an old envelope with a newer `seq` (AAD).
- **Cannot** roll a key back within a client process that already saw a newer `seq` (`rollback`). A fresh process has no history and will read whatever `seq` it is served — persist `seq` per key if that matters.
- **Cannot** insert its own device into the approval by swapping the pairing public key (the approver compares a phrase read from the new device's screen) or hand the new device its own DEK (the new device compares the approver's phrase and `crypto_box_open_easy` fails for any other sender key).
- **Can** withhold or delete rows. Metadata (key ids, seq, timing) is visible.
- The mock store's "plaintext" check is a tripwire, not a control: it refuses banned field names and a payload body that is **bare or dashed digits** (`^[0-9][0-9 -]{4,38}[0-9]$`). Anything else — digits with a prefix or newline, base64/UTF-16/JSON-wrapped digits, any non-numeric secret — passes. The only guarantee that a row is ciphertext is that every client seals before `put`.

## Dependency

`libsodium-wrappers-sumo@0.8.4` (exact pin, lockfile integrity, bundled types, WASM inlined so the install works offline once cached). The standard `libsodium-wrappers@0.8.4` build also declares and exports `crypto_pwhash`; switching to it (≈1.6 MB smaller) is a runtime check away and not done here.

## Tests

```sh
npm --prefix packages/ppomi-vault test
node --experimental-strip-types packages/ppomi-vault/example/src/main.ts
```
