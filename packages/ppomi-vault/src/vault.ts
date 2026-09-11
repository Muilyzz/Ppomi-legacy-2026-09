import {
  KEY_LEN,
  NONCE_LEN,
  TAG_LEN,
  VAULT_VERSION,
  open,
  payloadAad,
  seal,
  wrapVaultKey,
  unwrapVaultKey,
  type DeviceKeyPair,
} from "./crypto.ts";

export type VaultErrorCode =
  | "invalid_identity"
  | "invalid_key"
  | "invalid_value"
  | "invalid"
  | "exists"
  | "plaintext_rejected";

export class VaultError extends Error {
  readonly code: VaultErrorCode;

  constructor(code: VaultErrorCode, message: string) {
    super(message);
    this.name = "VaultError";
    this.code = code;
  }
}

/** Same id MZZ-47 `ppomi-secrets` uses. Put on Mac, get on Win. Never a cert blob. */
export const KB_STAR_BIZ_ACCOUNT_KEY = "ppomi/kb-star-biz/account";

const KEY_PATTERN = /^ppomi\/[a-z0-9](?:[a-z0-9./-]{0,126}[a-z0-9])?$/;
const MAX_PLAINTEXT_BYTES = 1024;
const ACCOUNTISH = /^[0-9][0-9 \-]{4,38}[0-9]$/;

export interface VaultEnvelope {
  readonly v: typeof VAULT_VERSION;
  readonly identityId: string;
  readonly id: string;
  /** nonce || ciphertext || tag, base64. The only payload bytes the store may keep. */
  readonly box: string;
}

export interface VaultPutOptions {
  readonly overwrite?: boolean;
}

export interface VaultEvidence {
  readonly key: string;
  readonly masked: string;
}

export interface CiphertextStore {
  put(envelope: VaultEnvelope): void;
  get(identityId: string, keyId: string): VaultEnvelope | undefined;
}

/**
 * In-memory stand-in for the remote row store. Accepts sealed envelopes only.
 * A real server must keep the same shape and must not add a plaintext column.
 */
export class MemoryCiphertextStore implements CiphertextStore {
  readonly #rows = new Map<string, VaultEnvelope>();

  put(envelope: VaultEnvelope): void {
    const accepted = assertCiphertextEnvelope(envelope);
    this.#rows.set(rowKey(accepted.identityId, accepted.id), { ...accepted });
  }

  get(identityId: string, keyId: string): VaultEnvelope | undefined {
    const row = this.#rows.get(rowKey(identityId, keyId));
    return row === undefined ? undefined : { ...row };
  }

  /** Test / example inspection. Every value is still an envelope. */
  snapshot(): readonly VaultEnvelope[] {
    return [...this.#rows.values()].map(row => ({ ...row }));
  }
}

export function assertCiphertextEnvelope(input: unknown): VaultEnvelope {
  if (input === null || typeof input !== "object") {
    throw new VaultError("plaintext_rejected", "store accepts ciphertext envelopes only");
  }
  const row = input as Record<string, unknown>;
  for (const banned of ["plaintext", "value", "accountNumber", "account_number"] as const) {
    if (banned in row) throw new VaultError("plaintext_rejected", "store accepts ciphertext envelopes only");
  }
  if (row.v !== VAULT_VERSION || typeof row.identityId !== "string" || typeof row.id !== "string" || typeof row.box !== "string") {
    throw new VaultError("plaintext_rejected", "store accepts ciphertext envelopes only");
  }
  let box: Buffer;
  try {
    box = Buffer.from(row.box, "base64");
  } catch {
    throw new VaultError("plaintext_rejected", "store accepts ciphertext envelopes only");
  }
  if (box.byteLength < NONCE_LEN + TAG_LEN + 1) {
    throw new VaultError("plaintext_rejected", "store accepts ciphertext envelopes only");
  }
  const body = box.subarray(NONCE_LEN, box.byteLength - TAG_LEN);
  if (!body.includes(0) && ACCOUNTISH.test(body.toString("utf8"))) {
    throw new VaultError("plaintext_rejected", "store accepts ciphertext envelopes only");
  }
  return { v: VAULT_VERSION, identityId: row.identityId, id: row.id, box: row.box };
}

/** True if any stored envelope field contains `needle` as UTF-8 / JSON text. */
export function storeContainsPlaintext(store: MemoryCiphertextStore, needle: string): boolean {
  if (needle.length === 0) return false;
  const utf8 = Buffer.from(needle, "utf8");
  for (const row of store.snapshot()) {
    if (JSON.stringify(row).includes(needle)) return true;
    const box = Buffer.from(row.box, "base64");
    if (box.includes(utf8)) return true;
  }
  return false;
}

export function vaultEvidence(keyId: string, value: string): VaultEvidence {
  assertKeyId(keyId);
  const digits = value.replace(/\D/g, "");
  return { key: keyId, masked: digits.length >= 4 ? `****${digits.slice(-4)}` : "****" };
}

export class ClientVault {
  readonly identityId: string;
  readonly #key: Buffer;
  readonly #store: CiphertextStore;

  constructor(identityId: string, vaultKey: Uint8Array, store: CiphertextStore) {
    assertIdentity(identityId);
    if (vaultKey.byteLength !== KEY_LEN) throw new VaultError("invalid", "vault key must be 32 bytes");
    this.identityId = identityId;
    this.#key = Buffer.from(vaultKey);
    this.#store = store;
  }

  put(keyId: string, plaintext: string, options?: VaultPutOptions): VaultEvidence {
    assertKeyId(keyId);
    assertPlaintext(plaintext);
    const existing = this.#store.get(this.identityId, keyId);
    if (existing !== undefined && options?.overwrite !== true) {
      throw new VaultError("exists", "vault key id already holds a value");
    }
    const box = seal(Buffer.from(plaintext, "utf8"), this.#key, payloadAad(this.identityId, keyId));
    this.#store.put({
      v: VAULT_VERSION,
      identityId: this.identityId,
      id: keyId,
      box: box.toString("base64"),
    });
    return vaultEvidence(keyId, plaintext);
  }

  get(keyId: string): string | undefined {
    assertKeyId(keyId);
    const row = this.#store.get(this.identityId, keyId);
    if (row === undefined) return undefined;
    try {
      return open(Buffer.from(row.box, "base64"), this.#key, payloadAad(this.identityId, keyId)).toString("utf8");
    } catch {
      throw new VaultError("invalid", "open failed");
    }
  }

  /** Existing-device approve: ciphertext the other device unwraps. */
  approveDevice(recipientPublicKey: Uint8Array): string {
    try {
      return wrapVaultKey(this.#key, recipientPublicKey, this.identityId).toString("base64");
    } catch {
      throw new VaultError("invalid", "approve failed");
    }
  }
}

export function acceptDeviceApproval(wrapped: string, device: DeviceKeyPair, identityId: string): Buffer {
  assertIdentity(identityId);
  try {
    return unwrapVaultKey(Buffer.from(wrapped, "base64"), device, identityId);
  } catch {
    throw new VaultError("invalid", "approve failed");
  }
}

function rowKey(identityId: string, keyId: string): string {
  return `${identityId}\n${keyId}`;
}

function assertIdentity(identityId: string): void {
  if (identityId.length === 0 || identityId.length > 128 || /[\n\r\0]/.test(identityId)) {
    throw new VaultError("invalid_identity", "identity id is a short stub, not a secret");
  }
}

function assertKeyId(keyId: string): void {
  if (!KEY_PATTERN.test(keyId) || keyId.includes("..") || keyId.includes("//")) {
    throw new VaultError("invalid_key", "vault key id must be ppomi/<id>");
  }
}

function assertPlaintext(value: string): void {
  if (value.length === 0 || Buffer.byteLength(value, "utf8") > MAX_PLAINTEXT_BYTES || value.includes("\0")) {
    throw new VaultError("invalid_value", "vault value must be 1..1024 bytes without NUL");
  }
}

