/**
 * Masked account capture for iPhone Mirroring reads.
 * Same KB shapes as `BankProfileCapture.accountPattern`. Raw digits stay off
 * StepResult / logs; the next slice (secret store) takes them via `handoff`.
 */

/** KB: 6-2-6, 4-2-6, 3-2-4-3, or 12–14 pasted digits. */
const KB_ACCOUNT_SOURCE =
  String.raw`(?<!\d)(?:\d{6}-\d{2}-\d{6}|\d{4}-\d{2}-\d{6}|\d{3}-\d{2}-\d{4}-\d{3}|\d{12,14})(?!\d)`;

export const KB_ACCOUNT_PATTERN = new RegExp(KB_ACCOUNT_SOURCE, "g");

function accountRe(): RegExp {
  return new RegExp(KB_ACCOUNT_SOURCE, "g");
}

export interface MaskedAccountCapture {
  readonly masked: string;
  readonly last4: string;
}

export function digitsOf(account: string): string {
  return account.replace(/\D/g, "");
}

export function maskAccountNumber(account: string): string {
  const digits = digitsOf(account);
  if (digits.length < 4) return "****";
  return `****${digits.slice(-4)}`;
}

export function isAccountText(text: string): boolean {
  return findAccountNumbers([text]).length > 0;
}

export function findAccountNumbers(texts: readonly string[]): string[] {
  const found: string[] = [];
  const seen = new Set<string>();
  for (const text of texts) {
    const matches = text.matchAll(accountRe());
    for (const match of matches) {
      const raw = match[0] ?? "";
      const digits = digitsOf(raw);
      if (digits.length === 0 || seen.has(digits)) continue;
      seen.add(digits);
      found.push(digits);
    }
  }
  return found;
}

/** Replace every KB-shaped account in `text` with `****last4`. */
export function maskAccountText(text: string): string {
  return text.replace(accountRe(), match => maskAccountNumber(match));
}

/**
 * One-shot port: ingest observed rows, expose only the mask, hand the raw
 * number to the secret-store slice once. Never logs.
 */
export class AccountCapturePort {
  private raw: string | undefined;

  ingest(texts: readonly string[]): MaskedAccountCapture | null {
    const found = findAccountNumbers(texts);
    if (found.length !== 1) {
      this.raw = undefined;
      return null;
    }
    const account = found[0]!;
    this.raw = account;
    return { masked: maskAccountNumber(account), last4: account.slice(-4) };
  }

  peekMasked(): MaskedAccountCapture | null {
    if (this.raw === undefined) return null;
    return { masked: maskAccountNumber(this.raw), last4: this.raw.slice(-4) };
  }

  /** Secret-store slice only. Clears after one call. */
  handoff(sink: (accountNumber: string) => void): boolean {
    if (this.raw === undefined) return false;
    const value = this.raw;
    this.raw = undefined;
    sink(value);
    return true;
  }
}
