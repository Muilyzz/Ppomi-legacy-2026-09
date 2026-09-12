# ADR: client E2E vault (MZZ-49)

Status: accepted for slice 1 (Mac↔Win ciphertext sync).

**Lock source:** PM-confirmed researcher input (2026-09-12). This file is that lock, not a menu.

## Decision

**libsodium AEAD + wrapped DEK sync. Server stores ciphertext only.**

| Piece | Lock |
| --- | --- |
| Data seal | libsodium **XChaCha20-Poly1305** (`crypto_aead_xchacha20poly1305_ietf`). Random 32-byte vault **DEK**. AAD `ppomi-vault-v1\|identityId\|keyId` |
| Device wrap | `crypto_box_seal` of the DEK to a device / auth-request X25519 pubkey |
| Recovery wrap | **Argon2id** (`crypto_pwhash` ALG_ARGON2ID13) → AEAD-wrap the DEK. Server keeps wrapped DEK + salt + non-decrypting verifier |
| Remote store | `{ kind, v, identityId, id, box }` plus, when needed, `salt` / `verifier` / pairing `publicKey` + `fingerprint` + `expiresAt` |
| Identity | Stub string now (Clerk `user_…` later). Account/meta may stay Clerk + server-key |
| Daily unlock | OS lock holds the **device private key** (MZZ-47 Keychain / CredMan). Unwrap DEK locally. No server master key |
| Pairing | **Bitwarden-style existing-device approve + fingerprint phrase.** QR is **out** of this PR |
| Package | `ppomi-vault` (`libsodium-wrappers-sumo` — sumo is required for `crypto_pwhash`) |
| Later | **age** for large evidence blobs — not in this PR |

`crypto_secretbox` is an allowed stand-in per the lock; this slice uses XChaCha20-Poly1305 AEAD so payload AAD binds identity + key id.

Mac `SharedRecordCrypto` (AES-GCM records vault) is a different store. Do not mix keys.

## Pairing (Mac→Win)

```text
Win                                      server / mock store                         Mac
  createAuthRequest()
    one-time box keypair
    fingerprint = generichash(pubkey)
  persist public meta+pubkey only  ──►  pair-request
                                                                              read request
                                                                              show fingerprint
                                                                              person confirms
                                                                              box_seal(DEK, win pubkey)
                                        dek-device wrap                ◄────  approve
  unwrap locally with request sk   ◄──  wrapped DEK
  ClientVault.get(keyId)           ◄──  payload ciphertext
```

Fingerprint phrase is eight hex bytes of `crypto_generichash(pubkey)` as `xxxx-xxxx-xxxx-xxxx`. Server may store that public material. Mac refuses wrap unless the spoken/typed phrase matches the recomputed hash.

QR / mobile proximity is a later slice (same wrap blob, different transport).

## Server must NEVER see

- vault DEK / device private keys / age identity secrets
- master passphrase / recovery key plaintext
- decrypted account numbers, balances, evidence, AX DOM/screens
- bank passwords / OTP / cert PINs
- support dumps of decrypted data

The mock store rejects those field names and fails tests if any of the fixture secrets appear in a snapshot.

## Server OK

- ciphertext blobs + nonce/version (`box`)
- wrapped DEK (`kind: dek-device` \| `dek-recovery`)
- KDF salt, non-decrypting auth verifier, Clerk user id (`identityId`)
- pairing request: pubkey, expiry, public fingerprint material

## Why not the alternatives

| Option | Rejected because |
| --- | --- |
| Node `aes-256-gcm` only (slice-0 draft) | PM lock is libsodium AEAD + Argon2id wrap |
| Server-held vault master key | Server can open the warehouse |
| Same-device `ppomi-secrets` only | KB path is acquire-on-Mac, fill-on-Win |
| Nitro / enclave decrypt | Out. Enclave plaintext is not E2E |
| Chat / StepResult / Linear digits | Forbidden channel |
| QR pairing in this PR | Mobile/proximity later |
| age in this PR | Optional later for large evidence |
| NPKI cert blobs in this vault | Certs stay in NPKI |

## Threat model (one page)

**Assets.** Vault DEK. Device/auth-request private keys. Recovery passphrase. Sealed payloads.

**Trusted.** Client processes that hold the DEK after unlock. The existing device that confirms a fingerprint and wraps.

**Untrusted.** Remote store, logs, chat, Linear, git, `StepResult`, agent memory, support exports. They may see the Server-OK columns. They must not see the Never list.

**In scope.** Store operator dumps every row. Log scraper. Mistaken `StepResult` print. Tests fail if the mock store can see fixture digits, the DEK, the recovery passphrase, or a device private key.

**Out of scope.** Compromised OS user. Approved-but-malicious second device. Offline brute-force of a weak recovery passphrase given salt+verifier. Lost-all-devices with no recovery passphrase.

**Breaks if.** A client puts UTF-8 digits as `box`. Approve skips fingerprint. Fill writes digits into chat/`StepResult`. Support copies a decrypted dump to the server.

## Hook points (no chat transfer)

Stable key id, same string as MZZ-47: `ppomi/kb-star-biz/account`.

| Ticket | When | Call | Must not |
| --- | --- | --- | --- |
| **MZZ-47 put** | After iPhone-mirroring handoff / `SecretStore.put` on Mac | `vault.put("ppomi/kb-star-biz/account", digits)` then drop `digits` | Chat, Linear, git, `StepResult` raw, server logs |
| **MZZ-48 fill** | Windows Edge KB cert path, account field only | `digits = vault.get(...)` → fill sink → drop. Evidence = `vaultEvidence` mask | Chat transfer Mac→Win; NPKI via this vault |

`ppomi-secrets` = local OS cache + device-key unlock. `ppomi-vault` = sync. Wiring those calls is follow-up on those tickets.

Argon2id ops/mem default in tests/example is `OPSLIMIT_MIN` / `MEMLIMIT_MIN`. Production callers use `interactiveKdfLimits()`.

## Out

Nitro, age blobs, QR camera, full-product E2E for Clerk meta, payment automation, real Clerk session, Mac/Win UI, live Supabase table.
