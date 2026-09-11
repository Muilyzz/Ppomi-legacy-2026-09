/**
 * Masked account capture for iPhone Mirroring reads.
 * Capture keeps the KB shapes of `BankProfileCapture.accountPattern`; masking is
 * wider (any 10–16 digit run) because OCR does not promise a shape. Separators
 * are whatever OCR renders between digit groups: ASCII or Unicode dashes, a
 * space, NBSP. Raw digits stay off StepResult / logs; the next slice (secret
 * store) takes them via `handoff`.
 */

/** One separator: a dash (optionally spaced) or one space-like character. */
const SEPARATOR =
  String.raw`(?:[ \u00A0\u2007\u202F]?[-\u2010\u2011\u2012\u2013\u2014\u2212\uFF0D][ \u00A0\u2007\u202F]?|[ \u00A0\u2007\u202F])`;

/** KB: 6-2-6, 4-2-6, 3-2-4-3 with separators, or 12–14 pasted digits. Captured as the account. */
const KB_ACCOUNT_SOURCE = String.raw`(?<!\d)(?:\d{6}${SEPARATOR}\d{2}${SEPARATOR}\d{6}|\d{4}${SEPARATOR}\d{2}${SEPARATOR}\d{6}|\d{3}${SEPARATOR}\d{2}${SEPARATOR}\d{4}${SEPARATOR}\d{3}|\d{12,14})(?!\d)`;

/**
 * Masked, never captured: any 10–16 digit run (Korean account lengths plus
 * 15–16 digit cards) with optional separators, bounded by non-digits. Amounts
 * keep their thousands commas, dates have 8 digits, times have colons.
 */
const DIGIT_RUN_SOURCE = String.raw`(?<!\d)\d(?:${SEPARATOR}?\d){9,15}(?!\d)`;

export const KB_ACCOUNT_PATTERN = new RegExp(KB_ACCOUNT_SOURCE, "g");

function kbAccountRe(): RegExp {
  return new RegExp(KB_ACCOUNT_SOURCE, "g");
}

function digitRunRe(): RegExp {
  return new RegExp(DIGIT_RUN_SOURCE, "g");
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

/** True for anything that gets masked, not only KB shapes: such a row is never tappable. */
export function isAccountText(text: string): boolean {
  return digitRunRe().test(text);
}

/** KB-shaped accounts only; the capture value must not absorb a neighbouring digit token. */
export function findAccountNumbers(texts: readonly string[]): string[] {
  const found: string[] = [];
  const seen = new Set<string>();
  for (const text of texts) {
    const matches = text.matchAll(kbAccountRe());
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

/** Replace every account-length digit run in `text` with `****last4`. */
export function maskAccountText(text: string): string {
  return text.replace(digitRunRe(), match => maskAccountNumber(match));
}

/**
 * Mask across the texts of one visual line: OCR may split `001234-56-789012`
 * into `001234-56` and `789012`, which no single text matches. The texts are
 * joined with one space; a run that spans several texts masks each of them
 * (`****` on the leading parts, `****last4` on the last).
 */
export function maskAccountRows(texts: readonly string[]): string[] {
  const out = [...texts];
  const offsets: number[] = [];
  let position = 0;
  for (const text of texts) {
    offsets.push(position);
    position += text.length + 1;
  }
  const joined = texts.join(" ");
  const matches = [...joined.matchAll(digitRunRe())].reverse();
  for (const match of matches) {
    const start = match.index;
    const end = start + match[0].length;
    const mask = maskAccountNumber(match[0]);
    const hit = texts
      .map((text, index) => ({ index, from: offsets[index]!, to: offsets[index]! + text.length }))
      .filter(row => row.from < end && start < row.to);
    hit.forEach((row, order) => {
      const localStart = Math.max(start, row.from) - row.from;
      const localEnd = Math.min(end, row.to) - row.from;
      const current = out[row.index]!;
      const replacement = order === hit.length - 1 ? mask : "****";
      out[row.index] = current.slice(0, localStart) + replacement + current.slice(localEnd);
    });
  }
  return out;
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
