import { timingSafeEqual } from "node:crypto";
import { inspect } from "node:util";
import * as sodiumNs from "libsodium-wrappers-sumo";

export const VAULT_VERSION = "ppomi-vault-v1";
export const RECOVERY_AAD = "ppomi-vault-recovery-v1";
export const RECOVERY_KDF_ALG = "argon2id13";
export const KEY_LEN = 32;
export const X25519_LEN = 32;
/** `senderPublicKey || nonce || crypto_box_easy(dek)`: 32 + 24 + (16 + 32). */
export const DEVICE_WRAP_LEN = X25519_LEN + 24 + 16 + KEY_LEN;

type Sodium = typeof sodiumNs;

/**
 * X25519 keypair. The private key is a plain field so libsodium can use it, but
 * `JSON.stringify` and `util.inspect` never include it.
 */
export class DeviceKeyPair {
  readonly publicKey: Uint8Array;
  readonly privateKey: Uint8Array;

  constructor(publicKey: Uint8Array, privateKey: Uint8Array) {
    assertLen(publicKey, X25519_LEN, "device public key");
    assertLen(privateKey, X25519_LEN, "device private key");
    this.publicKey = publicKey;
    this.privateKey = privateKey;
  }

  toJSON(): { publicKey: string } {
    return { publicKey: Buffer.from(this.publicKey).toString("base64") };
  }

  [inspect.custom](): string {
    return "DeviceKeyPair(private key redacted)";
  }
}

export interface KdfLimits {
  readonly opsLimit: number;
  readonly memLimit: number;
}

/** Stored next to the wrapped DEK so a later `open` derives with the same parameters. */
export interface RecoveryKdf extends KdfLimits {
  readonly alg: typeof RECOVERY_KDF_ALG;
}

export interface RecoveryWrap {
  readonly wrappedDek: Uint8Array;
  readonly salt: Uint8Array;
  readonly verifier: Uint8Array;
  readonly kdf: RecoveryKdf;
}

/** What the new device publishes through the store. No fingerprint: the approver recomputes it. */
export interface AuthRequestPublic {
  readonly requestId: string;
  readonly identityId: string;
  readonly publicKey: Uint8Array;
  readonly expiresAt: number;
}

/**
 * The new device's side of a pairing. `fingerprint` is shown on this device's
 * screen for the person to read to the approving device; it never goes to the
 * store. `toJSON` / `util.inspect` omit the private key.
 */
export class AuthRequest {
  readonly public: AuthRequestPublic;
  readonly device: DeviceKeyPair;
  readonly fingerprint: string;

  constructor(publicPart: AuthRequestPublic, device: DeviceKeyPair) {
    this.public = publicPart;
    this.device = device;
    this.fingerprint = pairingFingerprint(device.publicKey);
  }

  toJSON(): { public: Omit<AuthRequestPublic, "publicKey"> & { publicKey: string }; fingerprint: string } {
    return {
      public: { ...this.public, publicKey: Buffer.from(this.public.publicKey).toString("base64") },
      fingerprint: this.fingerprint,
    };
  }

  [inspect.custom](): string {
    return `AuthRequest(${this.public.requestId}, ${this.fingerprint}, private key redacted)`;
  }
}

export async function readyVault(): Promise<void> {
  await sodiumNs.ready;
}

function n(): Sodium {
  // ESM named import is a namespace; AEAD symbols land on the default after ready.
  const sodium = (sodiumNs as unknown as { default?: Sodium }).default;
  if (sodium === undefined || typeof sodium.crypto_aead_xchacha20poly1305_ietf_encrypt !== "function") {
    throw new Error("readyVault");
  }
  return sodium;
}

export function nonceLen(): number {
  return n().crypto_aead_xchacha20poly1305_ietf_NPUBBYTES;
}

export function tagLen(): number {
  return n().crypto_aead_xchacha20poly1305_ietf_ABYTES;
}

/** Default for production wraps: `crypto_pwhash_*_MODERATE` (≈0.5 s in the WASM build). */
export function defaultKdfLimits(): KdfLimits {
  const s = n();
  return { opsLimit: s.crypto_pwhash_OPSLIMIT_MODERATE, memLimit: s.crypto_pwhash_MEMLIMIT_MODERATE };
}

/** Floor: anything below `crypto_pwhash_*_INTERACTIVE` is refused on wrap and on open. */
export function interactiveKdfLimits(): KdfLimits {
  const s = n();
  return { opsLimit: s.crypto_pwhash_OPSLIMIT_INTERACTIVE, memLimit: s.crypto_pwhash_MEMLIMIT_INTERACTIVE };
}

export function assertKdfLimits(limits: KdfLimits): void {
  const floor = interactiveKdfLimits();
  if (
    !Number.isInteger(limits.opsLimit) ||
    !Number.isInteger(limits.memLimit) ||
    limits.opsLimit < floor.opsLimit ||
    limits.memLimit < floor.memLimit
  ) {
    throw new Error("weak_kdf");
  }
}

export function createDek(): Uint8Array {
  return n().randombytes_buf(KEY_LEN);
}

export function createDeviceKeyPair(): DeviceKeyPair {
  const pair = n().crypto_box_keypair();
  return new DeviceKeyPair(pair.publicKey, pair.privateKey);
}

/** Binds version, owner, key id and the monotonic sequence, so a stale envelope cannot be re-labelled. */
export function payloadAad(identityId: string, keyId: string, seq: number): Uint8Array {
  return new TextEncoder().encode(`${VAULT_VERSION}|${identityId}|${keyId}|${seq}`);
}

export function seal(plaintext: Uint8Array, dek: Uint8Array, aad: Uint8Array): Uint8Array {
  const s = n();
  assertLen(dek, KEY_LEN, "dek");
  const nonce = s.randombytes_buf(s.crypto_aead_xchacha20poly1305_ietf_NPUBBYTES);
  const ciphertext = s.crypto_aead_xchacha20poly1305_ietf_encrypt(plaintext, aad, null, nonce, dek);
  return concat(nonce, ciphertext);
}

export function open(box: Uint8Array, dek: Uint8Array, aad: Uint8Array): Uint8Array {
  const s = n();
  assertLen(dek, KEY_LEN, "dek");
  const npub = s.crypto_aead_xchacha20poly1305_ietf_NPUBBYTES;
  if (box.byteLength < npub + s.crypto_aead_xchacha20poly1305_ietf_ABYTES + 1) throw new Error("invalid");
  const nonce = box.subarray(0, npub);
  const ciphertext = box.subarray(npub);
  return s.crypto_aead_xchacha20poly1305_ietf_decrypt(null, ciphertext, aad, nonce, dek);
}

/**
 * Authenticated wrap: `crypto_box_easy` from the sender's device key to the
 * recipient's public key, prefixed with the sender's public key. The recipient
 * checks that public key against a fingerprint read out-of-band before opening,
 * so a store that swaps in its own wrap is refused.
 */
export function wrapDekForDevice(dek: Uint8Array, recipientPublicKey: Uint8Array, sender: DeviceKeyPair): Uint8Array {
  const s = n();
  assertLen(dek, KEY_LEN, "dek");
  assertLen(recipientPublicKey, X25519_LEN, "device public key");
  const nonce = s.randombytes_buf(s.crypto_box_NONCEBYTES);
  const box = s.crypto_box_easy(dek, nonce, recipientPublicKey, sender.privateKey);
  return concat(sender.publicKey, nonce, box);
}

export function unwrapDekForDevice(wrapped: Uint8Array, device: DeviceKeyPair, senderFingerprint: string): Uint8Array {
  const s = n();
  if (wrapped.byteLength !== DEVICE_WRAP_LEN) throw new Error("invalid");
  const senderPublicKey = wrapped.subarray(0, X25519_LEN);
  const nonce = wrapped.subarray(X25519_LEN, X25519_LEN + s.crypto_box_NONCEBYTES);
  const box = wrapped.subarray(X25519_LEN + s.crypto_box_NONCEBYTES);
  if (!fingerprintsMatch(pairingFingerprint(senderPublicKey), senderFingerprint)) throw new Error("fingerprint");
  const dek = s.crypto_box_open_easy(box, nonce, senderPublicKey, device.privateKey);
  if (dek.byteLength !== KEY_LEN) throw new Error("invalid");
  return dek;
}

/** Wrap DEK with Argon2id(passphrase). Server keeps wrapped DEK + salt + KDF parameters + verifier only. */
export function wrapDekForRecovery(
  dek: Uint8Array,
  passphrase: string,
  limits: KdfLimits = defaultKdfLimits(),
): RecoveryWrap {
  const s = n();
  assertLen(dek, KEY_LEN, "dek");
  if (passphrase.length === 0) throw new Error("passphrase");
  assertKdfLimits(limits);
  const kdf: RecoveryKdf = { alg: RECOVERY_KDF_ALG, opsLimit: limits.opsLimit, memLimit: limits.memLimit };
  const salt = s.randombytes_buf(s.crypto_pwhash_SALTBYTES);
  const wrappingKey = deriveRecoveryKey(passphrase, salt, kdf);
  const nonce = s.randombytes_buf(s.crypto_aead_xchacha20poly1305_ietf_NPUBBYTES);
  const ciphertext = s.crypto_aead_xchacha20poly1305_ietf_encrypt(
    dek,
    new TextEncoder().encode(RECOVERY_AAD),
    null,
    nonce,
    wrappingKey,
  );
  return { wrappedDek: concat(nonce, ciphertext), salt, verifier: recoveryVerifier(wrappingKey), kdf };
}

export function unwrapDekForRecovery(wrap: RecoveryWrap, passphrase: string): Uint8Array {
  const s = n();
  if (wrap.kdf.alg !== RECOVERY_KDF_ALG) throw new Error("invalid");
  assertKdfLimits(wrap.kdf);
  const wrappingKey = deriveRecoveryKey(passphrase, wrap.salt, wrap.kdf);
  if (!equalBytes(recoveryVerifier(wrappingKey), wrap.verifier)) throw new Error("invalid");
  const npub = s.crypto_aead_xchacha20poly1305_ietf_NPUBBYTES;
  const dek = s.crypto_aead_xchacha20poly1305_ietf_decrypt(
    null,
    wrap.wrappedDek.subarray(npub),
    new TextEncoder().encode(RECOVERY_AAD),
    wrap.wrappedDek.subarray(0, npub),
    wrappingKey,
  );
  if (dek.byteLength !== KEY_LEN) throw new Error("invalid");
  return dek;
}

/** Fingerprint phrase of a device public key: 8 bytes of BLAKE2b as `xxxx-xxxx-xxxx-xxxx`. Public. */
export function pairingFingerprint(publicKey: Uint8Array): string {
  const digest = n().crypto_generichash(8, publicKey, null);
  const hex = Buffer.from(digest).toString("hex");
  return `${hex.slice(0, 4)}-${hex.slice(4, 8)}-${hex.slice(8, 12)}-${hex.slice(12, 16)}`;
}

export function fingerprintsMatch(left: string, right: string): boolean {
  const a = Buffer.from(left, "utf8");
  const b = Buffer.from(right, "utf8");
  return a.byteLength === b.byteLength && timingSafeEqual(a, b);
}

/** New device: one-time keypair. Only `public` goes to the store; `fingerprint` goes on this device's screen. */
export function createAuthRequest(identityId: string, ttlMs = 5 * 60 * 1000): AuthRequest {
  const device = createDeviceKeyPair();
  return new AuthRequest(
    {
      requestId: Buffer.from(n().randombytes_buf(8)).toString("hex"),
      identityId,
      publicKey: device.publicKey,
      expiresAt: Date.now() + ttlMs,
    },
    device,
  );
}

/**
 * Existing device: `fingerprintReadFromNewDevice` must be what the person read or
 * typed from the new device's own screen. It is compared against the fingerprint
 * recomputed from the public key the store relayed; the store holds no fingerprint,
 * so there is nothing it could pass back to satisfy this check.
 */
export function approveAuthRequest(
  dek: Uint8Array,
  request: AuthRequestPublic,
  fingerprintReadFromNewDevice: string,
  approver: DeviceKeyPair,
): Uint8Array {
  if (Date.now() >= request.expiresAt) throw new Error("expired");
  if (!fingerprintsMatch(pairingFingerprint(request.publicKey), fingerprintReadFromNewDevice)) {
    throw new Error("fingerprint");
  }
  return wrapDekForDevice(dek, request.publicKey, approver);
}

function deriveRecoveryKey(passphrase: string, salt: Uint8Array, kdf: RecoveryKdf): Uint8Array {
  const s = n();
  return s.crypto_pwhash(KEY_LEN, passphrase, salt, kdf.opsLimit, kdf.memLimit, s.crypto_pwhash_ALG_ARGON2ID13);
}

function recoveryVerifier(wrappingKey: Uint8Array): Uint8Array {
  return n().crypto_generichash(KEY_LEN, wrappingKey, new TextEncoder().encode("ppomi-vault-verify-v1"));
}

function equalBytes(left: Uint8Array, right: Uint8Array): boolean {
  const a = Buffer.from(left);
  const b = Buffer.from(right);
  return a.byteLength === b.byteLength && timingSafeEqual(a, b);
}

function concat(...parts: readonly Uint8Array[]): Uint8Array {
  const out = new Uint8Array(parts.reduce((total, part) => total + part.byteLength, 0));
  let offset = 0;
  for (const part of parts) {
    out.set(part, offset);
    offset += part.byteLength;
  }
  return out;
}

function assertLen(bytes: Uint8Array, length: number, label: string): void {
  if (bytes.byteLength !== length) throw new Error(label);
}
