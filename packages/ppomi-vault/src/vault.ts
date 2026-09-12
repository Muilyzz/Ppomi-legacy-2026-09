import {
  DEVICE_WRAP_LEN,
  KEY_LEN,
  RECOVERY_KDF_ALG,
  VAULT_VERSION,
  approveAuthRequest,
  assertKdfLimits,
  createDek,
  createDeviceKeyPair,
  defaultKdfLimits,
  nonceLen,
  open,
  pairingFingerprint,
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
  type RecoveryKdf,
  type RecoveryWrap,
} from "./crypto.ts";

export type VaultErrorCode =
  | "invalid_identity"
  | "invalid_key"
  | "invalid_value"
  | "invalid"
  | "exists"
  | "stale"
  | "rollback"
  | "weak_kdf"
  | "fingerprint_mismatch"
  | "expired"
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
/** Internal rows (DEK wraps, pairing requests) live here; payload `put`/`get`/`delete` refuse it. */
export const RESERVED_KEY_PREFIX = "ppomi/vault/";

const KEY_PATTERN = /^ppomi\/[a-z0-9](?:[a-z0-9./-]{0,126}[a-z0-9])?$/;
const MAX_PLAINTEXT_BYTES = 1024;
/** Tripwire only: a body that is bare or dashed digits. Anything else is not inspected (see README). */
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
  "fingerprint",
] as const;

export type ServerRecordKind = "payload" | "dek-device" | "dek-recovery" | "pair-request";

export interface PayloadRecord {
  readonly kind: "payload";
  readonly v: typeof VAULT_VERSION;
  readonly identityId: string;
  readonly id: string;
  /** Monotonic per (identityId, id); bound into the AAD. */
  readonly seq: number;
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
  readonly kdf: RecoveryKdf;
}

export interface PairingRequestRecord {
  readonly kind: "pair-request";
  readonly v: typeof VAULT_VERSION;
  readonly identityId: string;
  readonly id: string;
  readonly publicKey: string;
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
  delete(identityId: string, keyId: string): void;
}

/**
 * In-memory stand-in for the remote row store. Accepts ciphertext, wrapped DEKs,
 * KDF salt/parameters/verifier, and pairing pubkey + expiry. Refuses a payload
 * whose `seq` does not increase and any change of a row's `kind`.
 */
export class MemoryCiphertextStore implements CiphertextStore {
  readonly #rows = new Map<string, ServerRecord>();

  put(record: ServerRecord): void {
    const accepted = assertServerRecord(record);
    const key = rowKey(accepted.identityId, accepted.id);
    const existing = this.#rows.get(key);
    if (existing !== undefined && existing.kind !== accepted.kind) {
      throw new VaultError("invalid", "row kind cannot change");
    }
    if (existing?.kind === "payload" && accepted.kind === "payload" && accepted.seq <= existing.seq) {
      throw new VaultError("stale", "payload seq must increase");
    }
    this.#rows.set(key, accepted);
  }

  get(identityId: string, keyId: string): ServerRecord | undefined {
    const row = this.#rows.get(rowKey(identityId, keyId));
    return row === undefined ? undefined : cloneRecord(row);
  }

  delete(identityId: string, keyId: string): void {
    this.#rows.delete(rowKey(identityId, keyId));
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
      return payloadRecord(row);
    case "dek-device":
      return {
        kind: "dek-device",
        v: VAULT_VERSION,
        identityId: String(row.identityId),
        id: String(row.id),
        box: decodeBox(row.box, DEVICE_WRAP_LEN, DEVICE_WRAP_LEN, false),
      };
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
      if (Buffer.from(value, "base64").includes(utf8)) return true;
    }
  }
  return false;
}

export function vaultEvidence(keyId: string, value: string): VaultEvidence {
  assertKeyId(keyId);
  const digits = value.replace(/\D/g, "");
  return { key: keyId, masked: digits.length >= 4 ? `****${digits.slice(-4)}` : "****" };
}

/** Row id of a device's long-term DEK wrap: one per device public key. */
export function deviceWrapKeyId(devicePublicKey: Uint8Array): string {
  return `${RESERVED_KEY_PREFIX}dek/device/${pairingFingerprint(devicePublicKey)}`;
}

export function persistDeviceDekWrap(
  store: CiphertextStore,
  identityId: string,
  dek: Uint8Array,
  recipientPublicKey: Uint8Array,
  sender: DeviceKeyPair,
  keyId = deviceWrapKeyId(recipientPublicKey),
): void {
  assertInternalKeyId(keyId);
  store.put({
    kind: "dek-device",
    v: VAULT_VERSION,
    identityId,
    id: keyId,
    box: Buffer.from(wrapDekForDevice(dek, recipientPublicKey, sender)).toString("base64"),
  });
}

export function persistRecoveryDekWrap(
  store: CiphertextStore,
  identityId: string,
  wrap: RecoveryWrap,
  keyId = `${RESERVED_KEY_PREFIX}dek/recovery`,
): void {
  assertInternalKeyId(keyId);
  store.put({
    kind: "dek-recovery",
    v: VAULT_VERSION,
    identityId,
    id: keyId,
    box: Buffer.from(wrap.wrappedDek).toString("base64"),
    salt: Buffer.from(wrap.salt).toString("base64"),
    verifier: Buffer.from(wrap.verifier).toString("base64"),
    kdf: { ...wrap.kdf },
  });
}

export function pairRequestKeyId(requestId: string): string {
  return `${RESERVED_KEY_PREFIX}pair/${requestId}`;
}

/** Publishes pubkey + expiry only. The fingerprint stays on the new device's screen. */
export function persistAuthRequest(store: CiphertextStore, request: AuthRequestPublic): void {
  store.put({
    kind: "pair-request",
    v: VAULT_VERSION,
    identityId: request.identityId,
    id: pairRequestKeyId(request.requestId),
    publicKey: Buffer.from(request.publicKey).toString("base64"),
    expiresAt: request.expiresAt,
  });
}

export class ClientVault {
  readonly identityId: string;
  readonly #dek: Buffer;
  readonly #store: CiphertextStore;
  readonly #device: DeviceKeyPair | undefined;
  /** Highest payload `seq` seen per key id in this process; `get` refuses anything older. */
  readonly #lastSeq = new Map<string, number>();

  constructor(identityId: string, dek: Uint8Array, store: CiphertextStore, device?: DeviceKeyPair) {
    assertIdentity(identityId);
    if (dek.byteLength !== KEY_LEN) throw new VaultError("invalid", "vault DEK must be 32 bytes");
    this.identityId = identityId;
    this.#dek = Buffer.from(dek);
    this.#store = store;
    this.#device = device;
  }

  /** First device: new DEK, self-wrap to this device's key, recovery wrap at `limits` (default MODERATE). */
  static firstDevice(
    identityId: string,
    store: CiphertextStore,
    recoveryPassphrase: string,
    limits: KdfLimits = defaultKdfLimits(),
  ): { vault: ClientVault; device: DeviceKeyPair } {
    const dek = createDek();
    const device = createDeviceKeyPair();
    const vault = new ClientVault(identityId, dek, store, device);
    persistDeviceDekWrap(store, identityId, dek, device.publicKey, device);
    persistRecoveryDekWrap(store, identityId, wrapRecovery(dek, recoveryPassphrase, limits));
    return { vault, device };
  }

  /** Shown on this device's screen so the person can read it to a device that must trust a wrap from here. */
  deviceFingerprint(): string {
    return pairingFingerprint(this.requireDevice().publicKey);
  }

  put(keyId: string, plaintext: string, options?: VaultPutOptions): VaultEvidence {
    assertKeyId(keyId);
    assertPlaintext(plaintext);
    const existing = this.#store.get(this.identityId, keyId);
    if (existing !== undefined && existing.kind !== "payload") throw new VaultError("invalid", "not a payload row");
    if (existing !== undefined && options?.overwrite !== true) {
      throw new VaultError("exists", "vault key id already holds a value");
    }
    const seq = Math.max(existing?.seq ?? 0, this.#lastSeq.get(keyId) ?? 0) + 1;
    const box = seal(Buffer.from(plaintext, "utf8"), this.#dek, payloadAad(this.identityId, keyId, seq));
    this.#store.put({
      kind: "payload",
      v: VAULT_VERSION,
      identityId: this.identityId,
      id: keyId,
      seq,
      box: Buffer.from(box).toString("base64"),
    });
    this.#lastSeq.set(keyId, seq);
    return vaultEvidence(keyId, plaintext);
  }

  get(keyId: string): string | undefined {
    assertKeyId(keyId);
    const row = this.#store.get(this.identityId, keyId);
    if (row === undefined) return undefined;
    if (row.kind !== "payload") throw new VaultError("invalid", "open failed");
    const last = this.#lastSeq.get(keyId);
    if (last !== undefined && row.seq < last) {
      throw new VaultError("rollback", `store returned seq ${row.seq}, already saw ${last}`);
    }
    let plaintext: string;
    try {
      plaintext = Buffer.from(
        open(Buffer.from(row.box, "base64"), this.#dek, payloadAad(this.identityId, keyId, row.seq)),
      ).toString("utf8");
    } catch {
      throw new VaultError("invalid", "open failed");
    }
    this.#lastSeq.set(keyId, row.seq);
    return plaintext;
  }

  delete(keyId: string): void {
    assertKeyId(keyId);
    this.#store.delete(this.identityId, keyId);
  }

  /**
   * Existing device: `fingerprintReadFromNewDevice` is what the person read off the
   * new device's screen. Wraps the DEK with this device's key (authenticated),
   * stores the wrap, and consumes the pairing request.
   */
  approveAuthRequest(request: AuthRequestPublic, fingerprintReadFromNewDevice: string): string {
    const approver = this.requireDevice();
    const wrapKeyId = `${RESERVED_KEY_PREFIX}dek/pair/${request.requestId}`;
    assertInternalKeyId(wrapKeyId);
    let wrapped: Uint8Array;
    try {
      wrapped = approveAuthRequest(this.#dek, request, fingerprintReadFromNewDevice, approver);
    } catch (error) {
      throw vaultErrorFrom(error, "approve failed");
    }
    this.#store.put({
      kind: "dek-device",
      v: VAULT_VERSION,
      identityId: this.identityId,
      id: wrapKeyId,
      box: Buffer.from(wrapped).toString("base64"),
    });
    this.#store.delete(request.identityId, pairRequestKeyId(request.requestId));
    return Buffer.from(wrapped).toString("base64");
  }

  private requireDevice(): DeviceKeyPair {
    if (this.#device === undefined) throw new VaultError("invalid", "this vault has no device key");
    return this.#device;
  }
}

/**
 * New device: `approverFingerprint` is what the person read off the existing
 * device's screen (`ClientVault.deviceFingerprint()`). A wrap from any other key,
 * including one the store minted itself, is refused before anything is opened.
 */
export function acceptAuthApproval(wrapped: string, request: AuthRequest, approverFingerprint: string): Buffer {
  try {
    return Buffer.from(unwrapDekForDevice(Buffer.from(wrapped, "base64"), request.device, approverFingerprint));
  } catch (error) {
    throw vaultErrorFrom(error, "approve failed");
  }
}

/** Daily unlock: open this device's own (or an approver's) DEK wrap with the device key in OS lock. */
export function openDeviceDek(record: DeviceDekWrapRecord, device: DeviceKeyPair, senderFingerprint: string): Buffer {
  try {
    return Buffer.from(unwrapDekForDevice(Buffer.from(record.box, "base64"), device, senderFingerprint));
  } catch (error) {
    throw vaultErrorFrom(error, "unlock failed");
  }
}

export function openRecoveryDek(record: RecoveryDekWrapRecord, passphrase: string): Buffer {
  try {
    return Buffer.from(
      unwrapDekForRecovery(
        {
          wrappedDek: Buffer.from(record.box, "base64"),
          salt: Buffer.from(record.salt, "base64"),
          verifier: Buffer.from(record.verifier, "base64"),
          kdf: record.kdf,
        },
        passphrase,
      ),
    );
  } catch (error) {
    throw vaultErrorFrom(error, "recovery failed");
  }
}

function wrapRecovery(dek: Uint8Array, passphrase: string, limits: KdfLimits): RecoveryWrap {
  try {
    return wrapDekForRecovery(dek, passphrase, limits);
  } catch (error) {
    throw vaultErrorFrom(error, "recovery wrap failed");
  }
}

function vaultErrorFrom(error: unknown, fallbackMessage: string): VaultError {
  if (error instanceof VaultError) return error;
  const message = error instanceof Error ? error.message : "";
  switch (message) {
    case "fingerprint":
      return new VaultError("fingerprint_mismatch", "fingerprint does not match the relayed public key");
    case "expired":
      return new VaultError("expired", "pairing request expired");
    case "weak_kdf":
      return new VaultError("weak_kdf", "Argon2id parameters below the INTERACTIVE floor");
    default:
      return new VaultError("invalid", fallbackMessage);
  }
}

function payloadRecord(row: Record<string, unknown>): PayloadRecord {
  if (typeof row.seq !== "number" || !Number.isInteger(row.seq) || row.seq < 1) {
    throw new VaultError("plaintext_rejected", "store accepts ciphertext only");
  }
  return {
    kind: "payload",
    v: VAULT_VERSION,
    identityId: String(row.identityId),
    id: String(row.id),
    seq: row.seq,
    box: decodeBox(row.box, nonceLen() + tagLen() + 1, undefined, true),
  };
}

function recoveryWrapRecord(row: Record<string, unknown>): RecoveryDekWrapRecord {
  if (typeof row.salt !== "string" || typeof row.verifier !== "string") {
    throw new VaultError("plaintext_rejected", "store accepts ciphertext only");
  }
  const kdf = row.kdf as Record<string, unknown> | undefined;
  if (
    kdf === null ||
    typeof kdf !== "object" ||
    kdf.alg !== RECOVERY_KDF_ALG ||
    typeof kdf.opsLimit !== "number" ||
    typeof kdf.memLimit !== "number"
  ) {
    throw new VaultError("plaintext_rejected", "store accepts ciphertext only");
  }
  const limits = { opsLimit: kdf.opsLimit, memLimit: kdf.memLimit };
  try {
    assertKdfLimits(limits);
  } catch (error) {
    throw vaultErrorFrom(error, "recovery record rejected");
  }
  const exact = nonceLen() + tagLen() + KEY_LEN;
  return {
    kind: "dek-recovery",
    v: VAULT_VERSION,
    identityId: String(row.identityId),
    id: String(row.id),
    box: decodeBox(row.box, exact, exact, false),
    salt: row.salt,
    verifier: row.verifier,
    kdf: { alg: RECOVERY_KDF_ALG, ...limits },
  };
}

function pairingRecord(row: Record<string, unknown>): PairingRequestRecord {
  if (typeof row.publicKey !== "string" || typeof row.expiresAt !== "number" || !Number.isFinite(row.expiresAt)) {
    throw new VaultError("plaintext_rejected", "store accepts ciphertext only");
  }
  if (Buffer.from(row.publicKey, "base64").byteLength !== 32) {
    throw new VaultError("plaintext_rejected", "store accepts ciphertext only");
  }
  return {
    kind: "pair-request",
    v: VAULT_VERSION,
    identityId: String(row.identityId),
    id: String(row.id),
    publicKey: row.publicKey,
    expiresAt: row.expiresAt,
  };
}

function decodeBox(value: unknown, minBytes: number, exactBytes: number | undefined, rejectAccountish: boolean): string {
  if (typeof value !== "string") throw new VaultError("plaintext_rejected", "store accepts ciphertext only");
  const box = Buffer.from(value, "base64");
  if (box.byteLength < minBytes || (exactBytes !== undefined && box.byteLength !== exactBytes)) {
    throw new VaultError("plaintext_rejected", "store accepts ciphertext only");
  }
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
    case "pair-request":
      return { ...row };
    case "dek-recovery":
      return { ...row, kdf: { ...row.kdf } };
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

/** Payload key ids: `ppomi/<id>` outside the reserved `ppomi/vault/` namespace. */
function assertKeyId(keyId: string): void {
  if (!KEY_PATTERN.test(keyId) || keyId.includes("..") || keyId.includes("//")) {
    throw new VaultError("invalid_key", "vault key id must be ppomi/<id>");
  }
  if (keyId.startsWith(RESERVED_KEY_PREFIX)) {
    throw new VaultError("invalid_key", `${RESERVED_KEY_PREFIX} is reserved for vault records`);
  }
}

function assertInternalKeyId(keyId: string): void {
  if (!KEY_PATTERN.test(keyId) || !keyId.startsWith(RESERVED_KEY_PREFIX)) {
    throw new VaultError("invalid_key", `vault records live under ${RESERVED_KEY_PREFIX}`);
  }
}

function assertPlaintext(value: string): void {
  if (value.length === 0 || Buffer.byteLength(value, "utf8") > MAX_PLAINTEXT_BYTES || value.includes("\0")) {
    throw new VaultError("invalid_value", "vault value must be 1..1024 bytes without NUL");
  }
}
