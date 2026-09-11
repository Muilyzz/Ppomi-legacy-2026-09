export type SecretStoreCode = "invalid_key" | "invalid_value" | "unavailable" | "failed";

export interface SecretExecResult {
  readonly status: number;
  readonly stdout: string;
  readonly stderr: string;
}

/** Injected in tests. Live backends must never log `args` that include a secret. */
export type SecretExec = (
  command: string,
  args: readonly string[],
  extraEnv?: Readonly<Record<string, string>>,
) => SecretExecResult;

export class SecretStoreError extends Error {
  readonly code: SecretStoreCode;

  constructor(code: SecretStoreCode, message: string) {
    super(message);
    this.name = "SecretStoreError";
    this.code = code;
  }
}

/** Local OS / test secret store. `get` is plaintext for the caller only. */
export interface SecretStore {
  put(key: string, value: string): void;
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

export function storeKbStarBizAccount(store: SecretStore, capture: AccountHandoff): SecretEvidence | null {
  let evidence: SecretEvidence | undefined;
  const ok = capture.handoff(account => {
    store.put(KB_STAR_BIZ_ACCOUNT_KEY, account);
    evidence = secretEvidence(KB_STAR_BIZ_ACCOUNT_KEY, account);
  });
  return ok && evidence !== undefined ? evidence : null;
}

export class FakeSecretStore implements SecretStore {
  readonly #items = new Map<string, string>();

  put(key: string, value: string): void {
    assertKey(key);
    assertValue(value);
    this.#items.set(key, value);
  }

  get(key: string): string | undefined {
    assertKey(key);
    return this.#items.get(key);
  }

  delete(key: string): void {
    assertKey(key);
    this.#items.delete(key);
  }
}
