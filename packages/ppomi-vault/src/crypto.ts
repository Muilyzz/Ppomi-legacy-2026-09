import {
  createCipheriv,
  createDecipheriv,
  createPrivateKey,
  createPublicKey,
  diffieHellman,
  generateKeyPairSync,
  hkdfSync,
  randomBytes,
  type KeyObject,
} from "node:crypto";

export const VAULT_VERSION = "ppomi-vault-v1";
export const WRAP_VERSION = "ppomi-vault-wrap-v1";
export const KEY_LEN = 32;
export const NONCE_LEN = 12;
export const TAG_LEN = 16;
export const X25519_LEN = 32;
const BOX_OVERHEAD = NONCE_LEN + TAG_LEN;

export interface DeviceKeyPair {
  readonly publicKey: Uint8Array;
  readonly privateKey: Uint8Array;
}

export function createVaultKey(): Uint8Array {
  return randomBytes(KEY_LEN);
}

export function createDeviceKeyPair(): DeviceKeyPair {
  const pair = generateKeyPairSync("x25519");
  return {
    publicKey: rawPublic(pair.publicKey),
    privateKey: rawPrivate(pair.privateKey),
  };
}

export function payloadAad(identityId: string, keyId: string): Buffer {
  return Buffer.from(`${VAULT_VERSION}|${identityId}|${keyId}`, "utf8");
}

export function seal(plaintext: Uint8Array, key: Uint8Array, aad: Uint8Array): Buffer {
  assertLen(key, KEY_LEN, "vault key");
  const nonce = randomBytes(NONCE_LEN);
  const cipher = createCipheriv("aes-256-gcm", key, nonce);
  cipher.setAAD(Buffer.from(aad));
  const ciphertext = Buffer.concat([cipher.update(plaintext), cipher.final()]);
  return Buffer.concat([nonce, ciphertext, cipher.getAuthTag()]);
}

export function open(box: Uint8Array, key: Uint8Array, aad: Uint8Array): Buffer {
  assertLen(key, KEY_LEN, "vault key");
  if (box.byteLength < BOX_OVERHEAD + 1) throw new Error("invalid");
  const buf = Buffer.from(box);
  const nonce = buf.subarray(0, NONCE_LEN);
  const tag = buf.subarray(buf.byteLength - TAG_LEN);
  const ciphertext = buf.subarray(NONCE_LEN, buf.byteLength - TAG_LEN);
  const decipher = createDecipheriv("aes-256-gcm", key, nonce);
  decipher.setAAD(Buffer.from(aad));
  decipher.setAuthTag(tag);
  return Buffer.concat([decipher.update(ciphertext), decipher.final()]);
}

/** Existing-device approve: wrap the vault key to a published X25519 public key. */
export function wrapVaultKey(vaultKey: Uint8Array, recipientPublicKey: Uint8Array, identityId: string): Buffer {
  assertLen(vaultKey, KEY_LEN, "vault key");
  assertLen(recipientPublicKey, X25519_LEN, "device public key");
  const ephemeral = generateKeyPairSync("x25519");
  const shared = diffieHellman({
    privateKey: ephemeral.privateKey,
    publicKey: publicFromRaw(recipientPublicKey),
  });
  const wrappingKey = Buffer.from(hkdfSync("sha256", shared, identityId.toLowerCase(), WRAP_VERSION, KEY_LEN));
  const aad = wrapAad(identityId, recipientPublicKey);
  const box = seal(vaultKey, wrappingKey, aad);
  return Buffer.concat([rawPublic(ephemeral.publicKey), box]);
}

export function unwrapVaultKey(wrapped: Uint8Array, device: DeviceKeyPair, identityId: string): Buffer {
  assertLen(device.publicKey, X25519_LEN, "device public key");
  assertLen(device.privateKey, X25519_LEN, "device private key");
  if (wrapped.byteLength !== X25519_LEN + BOX_OVERHEAD + KEY_LEN) throw new Error("invalid");
  const buf = Buffer.from(wrapped);
  const ephemeralPublic = buf.subarray(0, X25519_LEN);
  const box = buf.subarray(X25519_LEN);
  const shared = diffieHellman({
    privateKey: privateFromRaw(device),
    publicKey: publicFromRaw(ephemeralPublic),
  });
  const wrappingKey = Buffer.from(hkdfSync("sha256", shared, identityId.toLowerCase(), WRAP_VERSION, KEY_LEN));
  const opened = open(box, wrappingKey, wrapAad(identityId, device.publicKey));
  if (opened.byteLength !== KEY_LEN) throw new Error("invalid");
  return opened;
}

function wrapAad(identityId: string, recipientPublicKey: Uint8Array): Buffer {
  return Buffer.concat([
    Buffer.from(`${WRAP_VERSION}|${identityId.toLowerCase()}|`, "utf8"),
    Buffer.from(recipientPublicKey),
  ]);
}

function rawPublic(key: KeyObject): Buffer {
  const jwk = key.export({ format: "jwk" });
  if (jwk.x === undefined) throw new Error("invalid");
  const raw = Buffer.from(jwk.x, "base64url");
  assertLen(raw, X25519_LEN, "device public key");
  return raw;
}

function rawPrivate(key: KeyObject): Buffer {
  const jwk = key.export({ format: "jwk" });
  if (jwk.d === undefined) throw new Error("invalid");
  const raw = Buffer.from(jwk.d, "base64url");
  assertLen(raw, X25519_LEN, "device private key");
  return raw;
}

function publicFromRaw(raw: Uint8Array): KeyObject {
  return createPublicKey({
    format: "jwk",
    key: { kty: "OKP", crv: "X25519", x: Buffer.from(raw).toString("base64url") },
  });
}

function privateFromRaw(device: DeviceKeyPair): KeyObject {
  return createPrivateKey({
    format: "jwk",
    key: {
      kty: "OKP",
      crv: "X25519",
      x: Buffer.from(device.publicKey).toString("base64url"),
      d: Buffer.from(device.privateKey).toString("base64url"),
    },
  });
}

function assertLen(bytes: Uint8Array, length: number, label: string): void {
  if (bytes.byteLength !== length) throw new Error(label);
}
