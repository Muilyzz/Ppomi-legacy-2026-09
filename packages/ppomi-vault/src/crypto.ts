import { timingSafeEqual } from "node:crypto";
import * as sodiumNs from "libsodium-wrappers-sumo";

export const VAULT_VERSION = "ppomi-vault-v1";
export const RECOVERY_AAD = "ppomi-vault-recovery-v1";
export const KEY_LEN = 32;

type Sodium = typeof sodiumNs;

export interface DeviceKeyPair {
  readonly publicKey: Uint8Array;
  readonly privateKey: Uint8Array;
}

export interface KdfLimits {
  readonly opsLimit: number;
  readonly memLimit: number;
}

export interface RecoveryWrap {
  readonly wrappedDek: Uint8Array;
  readonly salt: Uint8Array;
  readonly verifier: Uint8Array;
}

export interface AuthRequestPublic {
  readonly requestId: string;
  readonly identityId: string;
  readonly publicKey: Uint8Array;
  readonly fingerprint: string;
  readonly expiresAt: number;
}

export interface AuthRequest {
  readonly public: AuthRequestPublic;
  readonly device: DeviceKeyPair;
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

/** Fast Argon2id for tests/example. Production callers should use `interactiveKdfLimits`. */
export function minKdfLimits(): KdfLimits {
  const s = n();
  return { opsLimit: s.crypto_pwhash_OPSLIMIT_MIN, memLimit: s.crypto_pwhash_MEMLIMIT_MIN };
}

export function interactiveKdfLimits(): KdfLimits {
  const s = n();
  return { opsLimit: s.crypto_pwhash_OPSLIMIT_INTERACTIVE, memLimit: s.crypto_pwhash_MEMLIMIT_INTERACTIVE };
}

export function createDek(): Uint8Array {
  return n().randombytes_buf(KEY_LEN);
}

export function createDeviceKeyPair(): DeviceKeyPair {
  const pair = n().crypto_box_keypair();
  return { publicKey: pair.publicKey, privateKey: pair.privateKey };
}

export function payloadAad(identityId: string, keyId: string): Uint8Array {
  return new TextEncoder().encode(`${VAULT_VERSION}|${identityId}|${keyId}`);
}

export function seal(plaintext: Uint8Array, dek: Uint8Array, aad: Uint8Array): Uint8Array {
  const s = n();
  assertLen(dek, KEY_LEN, "dek");
  const nonce = s.randombytes_buf(s.crypto_aead_xchacha20poly1305_ietf_NPUBBYTES);
  const ciphertext = s.crypto_aead_xchacha20poly1305_ietf_encrypt(plaintext, aad, null, nonce, dek);
  const out = new Uint8Array(nonce.length + ciphertext.length);
  out.set(nonce, 0);
  out.set(ciphertext, nonce.length);
  return out;
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

/** Wrap DEK to a device/auth-request X25519 public key (`crypto_box_seal`). */
export function wrapDekForDevice(dek: Uint8Array, recipientPublicKey: Uint8Array): Uint8Array {
  assertLen(dek, KEY_LEN, "dek");
  return n().crypto_box_seal(dek, recipientPublicKey);
}

export function unwrapDekForDevice(wrapped: Uint8Array, device: DeviceKeyPair): Uint8Array {
  const dek = n().crypto_box_seal_open(wrapped, device.publicKey, device.privateKey);
  if (dek.byteLength !== KEY_LEN) throw new Error("invalid");
  return dek;
}

/** Wrap DEK with Argon2id(passphrase). Server keeps wrapped DEK + salt + verifier only. */
export function wrapDekForRecovery(dek: Uint8Array, passphrase: string, limits: KdfLimits): RecoveryWrap {
  const s = n();
  assertLen(dek, KEY_LEN, "dek");
  if (passphrase.length === 0) throw new Error("passphrase");
  const salt = s.randombytes_buf(s.crypto_pwhash_SALTBYTES);
  const wrappingKey = deriveRecoveryKey(passphrase, salt, limits);
  const nonce = s.randombytes_buf(s.crypto_aead_xchacha20poly1305_ietf_NPUBBYTES);
  const ciphertext = s.crypto_aead_xchacha20poly1305_ietf_encrypt(
    dek,
    new TextEncoder().encode(RECOVERY_AAD),
    null,
    nonce,
    wrappingKey,
  );
  const wrappedDek = new Uint8Array(nonce.length + ciphertext.length);
  wrappedDek.set(nonce, 0);
  wrappedDek.set(ciphertext, nonce.length);
  return { wrappedDek, salt, verifier: recoveryVerifier(wrappingKey) };
}

export function unwrapDekForRecovery(
  wrap: RecoveryWrap,
  passphrase: string,
  limits: KdfLimits,
): Uint8Array {
  const s = n();
  const wrappingKey = deriveRecoveryKey(passphrase, wrap.salt, limits);
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

/** Public fingerprint phrase of an auth-request pubkey (server may store this). */
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

/** Win: one-time auth-request keypair. Server gets `public` only. */
export function createAuthRequest(identityId: string, ttlMs = 5 * 60 * 1000): AuthRequest {
  const device = createDeviceKeyPair();
  return {
    public: {
      requestId: Buffer.from(n().randombytes_buf(8)).toString("hex"),
      identityId,
      publicKey: device.publicKey,
      fingerprint: pairingFingerprint(device.publicKey),
      expiresAt: Date.now() + ttlMs,
    },
    device,
  };
}

export function approveAuthRequest(
  dek: Uint8Array,
  request: AuthRequestPublic,
  confirmedFingerprint: string,
): Uint8Array {
  if (Date.now() >= request.expiresAt) throw new Error("expired");
  const computed = pairingFingerprint(request.publicKey);
  if (!fingerprintsMatch(computed, request.fingerprint) || !fingerprintsMatch(computed, confirmedFingerprint)) {
    throw new Error("fingerprint");
  }
  return wrapDekForDevice(dek, request.publicKey);
}

function deriveRecoveryKey(passphrase: string, salt: Uint8Array, limits: KdfLimits): Uint8Array {
  const s = n();
  return s.crypto_pwhash(
    KEY_LEN,
    passphrase,
    salt,
    limits.opsLimit,
    limits.memLimit,
    s.crypto_pwhash_ALG_ARGON2ID13,
  );
}

function recoveryVerifier(wrappingKey: Uint8Array): Uint8Array {
  return n().crypto_generichash(KEY_LEN, wrappingKey, new TextEncoder().encode("ppomi-vault-verify-v1"));
}

function equalBytes(left: Uint8Array, right: Uint8Array): boolean {
  const a = Buffer.from(left);
  const b = Buffer.from(right);
  return a.byteLength === b.byteLength && timingSafeEqual(a, b);
}

function assertLen(bytes: Uint8Array, length: number, label: string): void {
  if (bytes.byteLength !== length) throw new Error(label);
}
