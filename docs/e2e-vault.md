# ADR: client E2E vault (MZZ-49)

Status: accepted for slice 1 (Mac↔Win ciphertext sync).

**Lock source:** PM-confirmed researcher input (2026-09-12). This file is that lock, not a menu.

## Decision

**libsodium AEAD + wrapped DEK sync. Server stores ciphertext only.**

| Piece | Lock |
| --- | --- |
| Data seal | libsodium **XChaCha20-Poly1305** (`crypto_aead_xchacha20poly1305_ietf`). Random 32-byte vault **DEK**. AAD `ppomi-vault-v1\|identityId\|keyId\|seq` — `seq` is monotonic per key; the store refuses a non-increasing `seq`, a client refuses a `seq` older than one it has seen |
| Device wrap | **Authenticated** `crypto_box_easy` from the approver's device key to the recipient's X25519 pubkey: `senderPub \|\| nonce \|\| box`. The recipient checks `senderPub` against a phrase read from the approver's screen before opening |
| Recovery wrap | **Argon2id** (`crypto_pwhash` ALG_ARGON2ID13) → AEAD-wrap the DEK. Default `MODERATE`; floor `INTERACTIVE` on wrap, open and store. Server keeps wrapped DEK + salt + `kdf { alg, opsLimit, memLimit }` + non-decrypting verifier |
| Remote store | `{ kind, v, identityId, id }` plus `seq` + `box` (payload), `box` (dek-device), `box` / `salt` / `verifier` / `kdf` (dek-recovery), `publicKey` / `expiresAt` (pair-request). **No fingerprint column** |
| Identity | Stub string now (Clerk `user_…` later). Account/meta may stay Clerk + server-key |
| Daily unlock | OS lock holds the **device private key** (MZZ-47 Keychain / CredMan). `openDeviceDek` on this device's own wrap `ppomi/vault/dek/device/<fingerprint>`. No server master key |
| Pairing | **Existing-device approve with two out-of-band phrases** (new device's → approver; approver's → new device). QR is **out** of this PR |
| Key ids | Payload ids `ppomi/<id>`; `ppomi/vault/` is reserved for vault records and refused by the payload API |
| Package | `ppomi-vault` (`libsodium-wrappers-sumo@0.8.4`; the standard `libsodium-wrappers@0.8.4` also exports `crypto_pwhash` — switching is a runtime check, not done here) |
| Later | **age** for large evidence blobs — not in this PR |

`crypto_secretbox` is an allowed stand-in per the lock; this slice uses XChaCha20-Poly1305 AEAD so payload AAD binds identity + key id.

Mac `SharedRecordCrypto` (AES-GCM records vault) is a different store. Do not mix keys.

## Pairing (Mac→Win)

```text
Win (new)                                server / mock store                         Mac (existing)
  createAuthRequest()
    one-time box keypair
    screen: win phrase = fp(win pub)
  persist pubkey + expiry only     ──►  pair-request (no phrase)
                                                                              read request
                                                                              person types the WIN phrase
                                                                              refuse unless fp(relayed pub) == typed
                                                                              box_easy(DEK, win pub, mac sk)
                                        dek-device wrap (senderPub‖nonce‖box) ◄──  approve; pair-request consumed
                                                                              screen: mac phrase = fp(mac pub)
  person types the MAC phrase
  refuse unless fp(senderPub) == typed
  box_open_easy with request sk    ◄──  wrapped DEK
  ClientVault.get(keyId)           ◄──  payload ciphertext
```

Fingerprint phrase is eight hex bytes of `crypto_generichash(pubkey)` as `xxxx-xxxx-xxxx-xxxx`. It is **never stored or relayed**: the approver recomputes the new device's phrase from the relayed public key and compares it with what the person read off the new device's screen (`approveAuthRequest(request, fingerprintReadFromNewDevice)`); the new device recomputes the approver's phrase from the wrap's sender key and compares it with what the person read off the approver's screen (`acceptAuthApproval(wrapped, request, approverFingerprint)`). Passing a relayed value into either parameter defeats the check — the store carries none, so there is nothing to pass.

QR / mobile proximity is a later slice (same wrap blob, different transport).

## Server must NEVER see

- vault DEK / device private keys / age identity secrets
- master passphrase / recovery key plaintext
- decrypted account numbers, balances, evidence, AX DOM/screens
- bank passwords / OTP / cert PINs
- fingerprint phrases (they are the out-of-band channel)
- support dumps of decrypted data

The mock store refuses those field names, a `fingerprint` column, a payload body that is bare or dashed digits, a non-increasing `seq`, a change of row `kind`, and Argon2id parameters below `INTERACTIVE`. That is a **tripwire**, not a control: digits with a prefix, base64/UTF-16/JSON-wrapped digits and any non-numeric secret pass it. The guarantee that a row is ciphertext is that every client seals before `put`; tests assert the fixture secrets (account, DEK, passphrase, private keys) are absent from every snapshot as UTF-8 and base64.

## Server OK

- ciphertext blobs + nonce/version + `seq` (`box`)
- wrapped DEK (`kind: dek-device` \| `dek-recovery`)
- KDF salt + parameters (`kdf`), non-decrypting auth verifier, Clerk user id (`identityId`)
- pairing request: pubkey, expiry

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

**In scope.** Store operator dumps every row. Store operator swaps the pairing public key for its own (refused: the approver compares the new device's phrase). Store operator hands the new device a wrap of its own DEK (refused: the new device compares the approver's phrase; `crypto_box_open_easy` fails for any other sender). Store operator re-labels an envelope to another key id / identity / `seq` (AAD). Store operator rewinds a key to an older envelope while a client that saw the newer one is running (`rollback`). Log scraper. Mistaken `StepResult` print or `JSON.stringify(request)` (private keys are omitted). Tests fail if the mock store can see fixture digits, the DEK, the recovery passphrase, or a device private key.

**Out of scope.** Compromised OS user. Approved-but-malicious second device. A person who "confirms" without reading the other screen. Offline brute-force of a weak recovery passphrase given salt+verifier (Argon2id `MODERATE` by default). Rewind served to a **fresh** process that has no `seq` history (persist `seq` per key if needed). Withheld or deleted rows. Lost-all-devices with no recovery passphrase.

**Breaks if.** A client puts UTF-8 digits as `box`. A UI passes anything the store relayed as either fingerprint parameter. Fill writes digits into chat/`StepResult`. Support copies a decrypted dump to the server.

## Hook points (no chat transfer)

Stable key id, same string as MZZ-47: `ppomi/kb-star-biz/account`.

| Ticket | When | Call | Must not |
| --- | --- | --- | --- |
| **MZZ-47 put** | After iPhone-mirroring handoff / `SecretStore.put` on Mac | `vault.put("ppomi/kb-star-biz/account", digits)` then drop `digits` | Chat, Linear, git, `StepResult` raw, server logs |
| **MZZ-48 fill** | Windows Edge KB cert path, account field only | `digits = vault.get(...)` → fill sink → drop. Evidence = `vaultEvidence` mask | Chat transfer Mac→Win; NPKI via this vault |

`ppomi-secrets` = local OS cache + device-key unlock. `ppomi-vault` = sync. Wiring those calls is follow-up on those tickets.

Argon2id defaults to `crypto_pwhash_*_MODERATE` (≈0.5 s in the WASM build); tests and the example pass `interactiveKdfLimits()` explicitly. Anything below `INTERACTIVE` is refused (`weak_kdf`) on wrap, on open, and by the store. The parameters used are stored in the `dek-recovery` record, so a later open never guesses.

## Out

Nitro, age blobs, QR camera, full-product E2E for Clerk meta, payment automation, real Clerk session, Mac/Win UI, live Supabase table.
