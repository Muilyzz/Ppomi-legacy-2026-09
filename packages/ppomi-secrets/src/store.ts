export type SecretStoreCode = "invalid_key" | "invalid_value" | "unavailable" | "exists" | "failed";

export interface SecretExecResult {
  readonly status: number;
  readonly stdout: string;
  readonly stderr: string;
}

/** Secret-bearing channels for a live backend. Never argv: argv is visible to `ps` and process telemetry. */
export interface SecretExecOptions {
  /** Added to the child's environment only (Windows value). */
  readonly extraEnv?: Readonly<Record<string, string>>;
  /** Written to the child's stdin, then closed (Mac `security -i` command line). */
  readonly input?: string;
}

/** Injected in tests. Live backends must never log `options` (`extraEnv`, `input`). */
export type SecretExec = (
  command: string,
  args: readonly string[],
  options?: SecretExecOptions,
) => SecretExecResult;

export interface SecretPutOptions {
  /** Replace an existing item. Without it `put` throws `exists`; nothing is overwritten silently. */
  readonly overwrite?: boolean;
}

export class SecretStoreError extends Error {
  readonly code: SecretStoreCode;

  constructor(code: SecretStoreCode, message: string) {
    super(message);
    this.name = "SecretStoreError";
    this.code = code;
  }
}

/**
 * Local OS / test secret store. `get` is plaintext for the caller; the OS backends
 * protect the item at rest and from other OS users, not from other processes of
 * the same user (see README "Protection level").
 */
export interface SecretStore {
  put(key: string, value: string, options?: SecretPutOptions): void;
  get(key: string): string | undefined;
  delete(key: string): void;
}

/** Catalog / StepResult evidence. Never includes the raw value. */
export interface SecretEvidence {
  readonly masked: string;
  readonly key: string;
}

/** Stable key for the KB스타기업뱅킹 business account (MZZ-47). Not a catalog field. */
export const KB_STAR_BIZ_ACCOUNT_KEY = "ppomi/kb-star-biz/account";

const KEY_PATTERN = /^ppomi\/[a-z0-9](?:[a-z0-9./-]{0,126}[a-z0-9])?$/;
const MAX_VALUE_BYTES = 1024;

export function assertKey(key: string): void {
  if (!KEY_PATTERN.test(key) || key.includes("..") || key.includes("//")) {
    throw new SecretStoreError("invalid_key", "secret key must be ppomi/<id>");
  }
}

export function assertValue(value: string): void {
  if (value.length === 0 || Buffer.byteLength(value, "utf8") > MAX_VALUE_BYTES || value.includes("\0")) {
    throw new SecretStoreError("invalid_value", "secret value must be 1..1024 bytes without NUL");
  }
}

/** Mask for Runtime / StepResult. Caller may keep `value`; this object must not. */
export function secretEvidence(key: string, value: string): SecretEvidence {
  assertKey(key);
  const digits = value.replace(/\D/g, "");
  const masked = digits.length >= 4 ? `****${digits.slice(-4)}` : "****";
  return { masked, key };
}

/** MZZ-46 `AccountCapturePort.handoff` shape. Raw digits never leave this function except into `store`. */
export interface AccountHandoff {
  handoff(sink: (accountNumber: string) => void): boolean;
}

/**
 * Consumes the capture once. If the key already holds a value and `overwrite` is
 * not set, `put` throws `exists` and the capture is still consumed (fail closed):
 * re-run the read step and pass `{ overwrite: true }` deliberately.
 */
export function storeKbStarBizAccount(
  store: SecretStore,
  capture: AccountHandoff,
  options?: SecretPutOptions,
): SecretEvidence | null {
  let evidence: SecretEvidence | undefined;
  const ok = capture.handoff(account => {
    store.put(KB_STAR_BIZ_ACCOUNT_KEY, account, options);
    evidence = secretEvidence(KB_STAR_BIZ_ACCOUNT_KEY, account);
  });
  return ok && evidence !== undefined ? evidence : null;
}
