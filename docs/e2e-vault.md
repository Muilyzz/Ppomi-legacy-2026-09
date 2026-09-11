# ADR: client E2E vault (MZZ-49)

Status: accepted for slice 1 (Mac↔Win ciphertext sync). Not a library freeze — replace the box if a later slice needs a different primitive; do not add a second box beside this one.

## Decision

**Sealed box + ciphertext sync. Node `node:crypto` only.**

| Piece | Choice |
| --- | --- |
| Payload seal | AES-256-GCM, 32-byte vault key, 12-byte nonce, AAD `ppomi-vault-v1\|identityId\|keyId` |
| Device approve | X25519 ephemeral + HKDF-SHA256 + AES-256-GCM wrap of the vault key (`ppomi-vault-wrap-v1`) |
| Remote store | Opaque envelope `{ v, identityId, id, box }`. `box` is nonce\|\|ciphertext\|\|tag (base64). No plaintext field |
| Identity | Stub string (Clerk `user_…` later). Account/meta may stay Clerk + server-key |
| Daily unlock | OS lock holds the vault key (Keychain / Credential Manager via MZZ-47 `ppomi-secrets`). Face ID unlocks the OS store — Ppomi does not keep a server master key |
| Pairing path | **Existing-device approve** (one). QR is the same wrap blob on a camera later — not built here |
| Package | New `ppomi-vault`. Does not extend unmerged `ppomi-secrets` (#55/#57) |

Same shape as Mac `SharedRecordCrypto` / `KeyWrap` (AES-GCM + X25519 wrap). Those stay on the records vault. This package is the TypeScript port for bank/evidence **payloads** that must cross Mac→Win without chat.

## Why not the alternatives

| Option | Rejected because |
| --- | --- |
| libsodium / tweetnacl / `@noble/ciphers` | Extra dep for AES-GCM + X25519 that Node 22 already has |
| Server-held vault master key (Clerk, Supabase Vault, KMS) | Server can open the warehouse. Lock forbids it |
| Same-device `ppomi-secrets` only | KB path is acquire-on-Mac, fill-on-Win |
| Nitro / enclave decrypt | Explicitly out. Enclave plaintext is not E2E |
| Chat / StepResult / Linear handoff of digits | Forbidden channel |
| Put NPKI cert blobs in this vault | Certs stay in NPKI. This vault is account/evidence plaintext, not a cert substitute |

## Threat model (one page)

**Assets.** Vault master key (32 bytes). Sealed payloads (account numbers, later evidence). Wrap blobs (key for a new device).

**Trusted.** The two client processes that hold the vault key after unlock. The first device that created the key. The approving device that wraps for a published X25519 public key.

**Untrusted.** The remote store, logs, chat, Linear, git, `StepResult`, agent memory, any server process. They may see envelopes and wrap blobs. They must not see vault keys or payload plaintext.

**In scope (this slice).** A curious store operator who dumps every row. A log scraper. A mistaken `console.log` of `StepResult`. Tests fail if the mock store can see the fixture digits.

**Out of scope (this slice).** Compromised OS user (same as `ppomi-secrets`: same-user processes can read Keychain). Malicious second device that the person approved. Recovery if every device is lost (no server recovery key — by design). Traffic analysis of key ids.

**Breaks if.** A client `put`s UTF-8 digits as `box`. A wrap is logged next to the device private key. Fill writes digits into `StepResult` or chat. A future “sync” copies Keychain items through a server-readable API.

## Pairing (existing-device approve)

```text
Win (new)                         Mac (existing)                    store
  createDeviceKeyPair()
  publish publicKey  ──────────►  wrapVaultKey(vaultKey, pub)
                                  store.put wrap envelope  ───►  ciphertext only
  unwrapVaultKey(box, priv) ◄──── store.get wrap
  ClientVault.get(keyId)    ◄──── store.get payload
```

Daily use after pairing: OS unlock → load vault key → `get` / `put`. No re-approve.

## Hook points (no chat transfer)

Stable key id, same string as MZZ-47: `ppomi/kb-star-biz/account`.

| Ticket | When | Call | Must not |
| --- | --- | --- | --- |
| **MZZ-47 put** | After iPhone-mirroring handoff / `SecretStore.put` on Mac | `vault.put("ppomi/kb-star-biz/account", digits)` then drop `digits` | Chat, Linear, git, `StepResult` raw, server logs |
| **MZZ-48 fill** | Windows Edge KB cert path, account field only | `digits = vault.get("ppomi/kb-star-biz/account")` → fill sink → drop `digits`. Evidence = `vaultEvidence` mask | Chat transfer Mac→Win; NPKI cert import via this vault |

`ppomi-secrets` remains the **local** OS cache and the daily-unlock holder of the vault key. `ppomi-vault` is the **sync** layer. Wiring those two calls is a follow-up on those tickets, not this PR.

## Out

Nitro, full-product E2E for Clerk meta, payment automation, real Clerk session, Mac/Win UI, QR camera, live Supabase table.
