import {
  KEY_LEN,
  VAULT_VERSION,
  approveAuthRequest,
  createDek,
  createDeviceKeyPair,
  minKdfLimits,
  nonceLen,
  open,
  payloadAad,
  seal,
  tagLen,
  unwrapDekForDevice,
  unwrapDekForRecovery,
  wrapDekForDevice,
  wrapDekForRecovery,
  type AuthRequest,
  type AuthRequestPublic,
  type DeviceKeyPair,
  type KdfLimits,
  type RecoveryWrap,
} from "./crypto.ts";

export type VaultErrorCode =
  | "invalid_identity"
  | "invalid_key"
  | "invalid_value"
  | "invalid"
  | "exists"
  | "plaintext_rejected"
  | "unavailable";

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
const BANNED_FIELDS = [
  "plaintext",
  "value",
  "accountNumber",
  "account_number",
  "dek",
  "privateKey",
  "passphrase",
  "recoveryKey",
  "masterKey",
] as const;

export type ServerRecordKind = "payload" | "dek-device" | "dek-recovery" | "pair-request";

export interface PayloadRecord {
  readonly kind: "payload";
  readonly v: typeof VAULT_VERSION;
  readonly identityId: string;
  readonly id: string;
  readonly box: string;
}

export interface DeviceDekWrapRecord {
  readonly kind: "dek-device";
  readonly v: typeof VAULT_VERSION;
  readonly identityId: string;
  readonly id: string;
  readonly box: string;
}

export interface RecoveryDekWrapRecord {
  readonly kind: "dek-recovery";
  readonly v: typeof VAULT_VERSION;
  readonly identityId: string;
  readonly id: string;
  readonly box: string;
  readonly salt: string;
  readonly verifier: string;
}

export interface PairingRequestRecord {
  readonly kind: "pair-request";
  readonly v: typeof VAULT_VERSION;
  readonly identityId: string;
  readonly id: string;
  readonly publicKey: string;
  readonly fingerprint: string;
  readonly expiresAt: number;
}

export type ServerRecord = PayloadRecord | DeviceDekWrapRecord | RecoveryDekWrapRecord | PairingRequestRecord;

export interface VaultPutOptions {
  readonly overwrite?: boolean;
}

export interface VaultEvidence {
  readonly key: string;
  readonly masked: string;
}

export interface CiphertextStore {
  put(record: ServerRecord): void;
  get(identityId: string, keyId: string): ServerRecord | undefined;
}

/**
 * In-memory stand-in for the remote row store.
 * Accepts ciphertext, wrapped DEKs, KDF salt/verifier, and pairing pubkey+fingerprint.
 */
export class MemoryCiphertextStore implements CiphertextStore {
  readonly #rows = new Map<string, ServerRecord>();

  put(record: ServerRecord): void {
    const accepted = assertServerRecord(record);
    this.#rows.set(rowKey(accepted.identityId, accepted.id), accepted);
  }

  get(identityId: string, keyId: string): ServerRecord | undefined {
    const row = this.#rows.get(rowKey(identityId, keyId));
    return row === undefined ? undefined : cloneRecord(row);
  }

  snapshot(): readonly ServerRecord[] {
    return [...this.#rows.values()].map(cloneRecord);
  }
}

export function assertServerRecord(input: unknown): ServerRecord {
  if (input === null || typeof input !== "object") {
    throw new VaultError("plaintext_rejected", "store accepts ciphertext only");
  }
  const row = input as Record<string, unknown>;
  for (const banned of BANNED_FIELDS) {
    if (banned in row) throw new VaultError("plaintext_rejected", "store accepts ciphertext only");
  }
  if (row.v !== VAULT_VERSION || typeof row.identityId !== "string" || typeof row.id !== "string") {
    throw new VaultError("plaintext_rejected", "store accepts ciphertext only");
  }
  const kind = row.kind;
  switch (kind) {
    case "payload":
      return requireBox(row, "payload", nonceLen() + tagLen() + 1);
    case "dek-device":
      return requireBox(row, "dek-device", 32 + 16 + KEY_LEN);
    case "dek-recovery":
      return recoveryWrapRecord(row);
    case "pair-request":
      return pairingRecord(row);
    default: {
      const _exhaustive: never = kind as never;
      void _exhaustive;
      throw new VaultError("plaintext_rejected", "store accepts ciphertext only");
    }
  }
}

export function storeContainsPlaintext(store: MemoryCiphertextStore, needle: string | Uint8Array): boolean {
  if (typeof needle === "string" && needle.length === 0) return false;
  const utf8 = typeof needle === "string" ? Buffer.from(needle, "utf8") : Buffer.from(needle);
  const text = typeof needle === "string" ? needle : null;
  for (const row of store.snapshot()) {
    const json = JSON.stringify(row);
    if (text !== null && json.includes(text)) return true;
    for (const value of Object.values(row)) {
      if (typeof value !== "string") continue;
      try {
        if (Buffer.from(value, "base64").includes(utf8)) return true;
      } catch {
        continue;
      }
    }
  }
  return false;
}

export function vaultEvidence(keyId: string, value: string): VaultEvidence {
  assertKeyId(keyId);
  const digits = value.replace(/\D/g, "");
  return { key: keyId, masked: digits.length >= 4 ? `****${digits.slice(-4)}` : "****" };
}

export function persistDeviceDekWrap(
  store: CiphertextStore,
  identityId: string,
  dek: Uint8Array,
  devicePublicKey: Uint8Array,
  keyId = "ppomi/vault/dek/device",
): void {
  store.put({
    kind: "dek-device",
    v: VAULT_VERSION,
    identityId,
    id: keyId,
    box: Buffer.from(wrapDekForDevice(dek, devicePublicKey)).toString("base64"),
  });
}

export function persistRecoveryDekWrap(
  store: CiphertextStore,
  identityId: string,
  wrap: RecoveryWrap,
  keyId = "ppomi/vault/dek/recovery",
): void {
  store.put({
    kind: "dek-recovery",
    v: VAULT_VERSION,
    identityId,
    id: keyId,
    box: Buffer.from(wrap.wrappedDek).toString("base64"),
    salt: Buffer.from(wrap.salt).toString("base64"),
    verifier: Buffer.from(wrap.verifier).toString("base64"),
  });
}

export function persistAuthRequest(store: CiphertextStore, request: AuthRequestPublic): void {
  store.put({
    kind: "pair-request",
    v: VAULT_VERSION,
    identityId: request.identityId,
    id: `ppomi/vault/pair/${request.requestId}`,
    publicKey: Buffer.from(request.publicKey).toString("base64"),
    fingerprint: request.fingerprint,
    expiresAt: request.expiresAt,
  });
}

export class ClientVault {
  readonly identityId: string;
  readonly #dek: Buffer;
  readonly #store: CiphertextStore;

  constructor(identityId: string, dek: Uint8Array, store: CiphertextStore) {
    assertIdentity(identityId);
    if (dek.byteLength !== KEY_LEN) throw new VaultError("invalid", "vault DEK must be 32 bytes");
    this.identityId = identityId;
    this.#dek = Buffer.from(dek);
    this.#store = store;
  }

  static firstDevice(
    identityId: string,
    store: CiphertextStore,
    recoveryPassphrase: string,
    limits: KdfLimits = minKdfLimits(),
  ): { vault: ClientVault; device: DeviceKeyPair } {
    const dek = createDek();
    const device = createDeviceKeyPair();
    const vault = new ClientVault(identityId, dek, store);
    persistDeviceDekWrap(store, identityId, dek, device.publicKey);
    persistRecoveryDekWrap(store, identityId, wrapDekForRecovery(dek, recoveryPassphrase, limits));
    return { vault, device };
  }

  put(keyId: string, plaintext: string, options?: VaultPutOptions): VaultEvidence {
    assertKeyId(keyId);
    assertPlaintext(plaintext);
    const existing = this.#store.get(this.identityId, keyId);
    if (existing !== undefined && options?.overwrite !== true) {
      throw new VaultError("exists", "vault key id already holds a value");
    }
    const box = seal(Buffer.from(plaintext, "utf8"), this.#dek, payloadAad(this.identityId, keyId));
    this.#store.put({
      kind: "payload",
      v: VAULT_VERSION,
      identityId: this.identityId,
      id: keyId,
      box: Buffer.from(box).toString("base64"),
    });
    return vaultEvidence(keyId, plaintext);
  }

  get(keyId: string): string | undefined {
    assertKeyId(keyId);
    const row = this.#store.get(this.identityId, keyId);
    if (row === undefined) return undefined;
    if (row.kind !== "payload") throw new VaultError("invalid", "open failed");
    try {
      return Buffer.from(open(Buffer.from(row.box, "base64"), this.#dek, payloadAad(this.identityId, keyId))).toString(
        "utf8",
      );
    } catch {
      throw new VaultError("invalid", "open failed");
    }
  }

  /** Mac: confirm the Win fingerprint phrase, then wrap DEK to the auth-request pubkey. */
  approveAuthRequest(request: AuthRequestPublic, confirmedFingerprint: string): string {
    try {
      const wrapped = approveAuthRequest(this.#dek, request, confirmedFingerprint);
      persistDeviceDekWrap(
        this.#store,
        this.identityId,
        this.#dek,
        request.publicKey,
        `ppomi/vault/dek/pair/${request.requestId}`,
      );
      return Buffer.from(wrapped).toString("base64");
    } catch {
      throw new VaultError("invalid", "approve failed");
    }
  }
}

export function acceptAuthApproval(wrapped: string, request: AuthRequest): Buffer {
  try {
    return Buffer.from(unwrapDekForDevice(Buffer.from(wrapped, "base64"), request.device));
  } catch {
    throw new VaultError("invalid", "approve failed");
  }
}

export function openRecoveryDek(
  record: RecoveryDekWrapRecord,
  passphrase: string,
  limits: KdfLimits = minKdfLimits(),
): Buffer {
  try {
    return Buffer.from(
      unwrapDekForRecovery(
        {
          wrappedDek: Buffer.from(record.box, "base64"),
          salt: Buffer.from(record.salt, "base64"),
          verifier: Buffer.from(record.verifier, "base64"),
        },
        passphrase,
        limits,
      ),
    );
  } catch {
    throw new VaultError("invalid", "recovery failed");
  }
}

function requireBox(
  row: Record<string, unknown>,
  kind: "payload" | "dek-device",
  minBytes: number,
): PayloadRecord | DeviceDekWrapRecord {
  const box = decodeBox(row.box, minBytes, kind === "payload");
  return { kind, v: VAULT_VERSION, identityId: String(row.identityId), id: String(row.id), box };
}

function recoveryWrapRecord(row: Record<string, unknown>): RecoveryDekWrapRecord {
  if (typeof row.salt !== "string" || typeof row.verifier !== "string") {
    throw new VaultError("plaintext_rejected", "store accepts ciphertext only");
  }
  return {
    kind: "dek-recovery",
    v: VAULT_VERSION,
    identityId: String(row.identityId),
    id: String(row.id),
    box: decodeBox(row.box, nonceLen() + tagLen() + KEY_LEN, false),
    salt: row.salt,
    verifier: row.verifier,
  };
}

function pairingRecord(row: Record<string, unknown>): PairingRequestRecord {
  if (
    typeof row.publicKey !== "string" ||
    typeof row.fingerprint !== "string" ||
    typeof row.expiresAt !== "number" ||
    !Number.isFinite(row.expiresAt)
  ) {
    throw new VaultError("plaintext_rejected", "store accepts ciphertext only");
  }
  return {
    kind: "pair-request",
    v: VAULT_VERSION,
    identityId: String(row.identityId),
    id: String(row.id),
    publicKey: row.publicKey,
    fingerprint: row.fingerprint,
    expiresAt: row.expiresAt,
  };
}

function decodeBox(value: unknown, minBytes: number, rejectAccountish: boolean): string {
  if (typeof value !== "string") throw new VaultError("plaintext_rejected", "store accepts ciphertext only");
  let box: Buffer;
  try {
    box = Buffer.from(value, "base64");
  } catch {
    throw new VaultError("plaintext_rejected", "store accepts ciphertext only");
  }
  if (box.byteLength < minBytes) throw new VaultError("plaintext_rejected", "store accepts ciphertext only");
  if (rejectAccountish) {
    const body = box.subarray(nonceLen(), box.byteLength - tagLen());
    if (!body.includes(0) && ACCOUNTISH.test(body.toString("utf8"))) {
      throw new VaultError("plaintext_rejected", "store accepts ciphertext only");
    }
  }
  return value;
}

function cloneRecord(row: ServerRecord): ServerRecord {
  switch (row.kind) {
    case "payload":
    case "dek-device":
      return { ...row };
    case "dek-recovery":
      return { ...row };
    case "pair-request":
      return { ...row };
    default: {
      const _exhaustive: never = row;
      return _exhaustive;
    }
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
