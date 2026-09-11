/**
 * URL shapes that may enter results and notes. Query strings and fragments carry
 * session tokens, so only origin + pathname ever leaves the runtime.
 */

/** Origin + pathname only; opaque origins (`about:`, `javascript:`, `data:`, `file:`) keep their scheme and path. */
export function publicUrl(url: string): string {
  const parsed = parse(url);
  if (parsed === null) return "(invalid url)";
  return parsed.origin === "null" ? `${parsed.protocol}${parsed.pathname}` : `${parsed.origin}${parsed.pathname}`;
}

/** Origin + pathname for a real (non-opaque) origin, else `null`. */
export function publicHttpUrl(url: string): string | null {
  const parsed = parse(url);
  if (parsed === null || parsed.origin === "null") return null;
  return `${parsed.origin}${parsed.pathname}`;
}

export function originOf(url: string): string {
  return parse(url)?.origin ?? "(invalid url)";
}

/**
 * Replace every URL-shaped token in free text with its public form, and keep only the
 * first line. This is URL-shaped redaction only: any other value a driver echoes in a
 * message (typed text, element values) remains that driver's contract to keep out.
 */
export function redactText(text: string): string {
  const firstLine = text.split(/\r?\n/, 1)[0] ?? "";
  return firstLine.replace(/[a-z][a-z0-9+.-]*:\/\/[^\s"'<>)]+/gi, match => publicUrl(match));
}

function parse(url: string): URL | null {
  try {
    return new URL(url);
  } catch {
    return null;
  }
}
