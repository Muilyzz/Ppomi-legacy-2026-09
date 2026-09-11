import type { BrowserPageDriver, PageSnapshot } from "./drivers.ts";
import type { PagePlaybookStep } from "./page-playbook.ts";
import { defaultPagePermission } from "./permissions.ts";
import type { MaybePromise } from "./playbook.ts";
import type { RuntimeCode } from "./emit-step-result.ts";
import type { Resolution, StepClass, UiDriver } from "./runtime-core.ts";
import { originOf, publicHttpUrl, publicUrl } from "./public-url.ts";
import type { StepTarget } from "./step-result.ts";

export type PageRef =
  | { readonly kind: "read" }
  | { readonly kind: "goto"; readonly url: string }
  | { readonly kind: "click"; readonly locator: string }
  | { readonly kind: "fill"; readonly locator: string; readonly text: string }
  | { readonly kind: "waitFor"; readonly locator: string };

/** A web page as a `UiDriver`: locator targets over one `BrowserPageDriver` port. */
export class PageSurface implements UiDriver<PageSnapshot, PageRef, PagePlaybookStep> {
  readonly surface = "page" as const;
  readonly driver = "page" as const;
  private readonly page: BrowserPageDriver;
  private readonly allowedOrigins: readonly string[] | undefined;

  constructor(port: BrowserPageDriver, allowedOrigins?: readonly string[]) {
    this.page = port;
    this.allowedOrigins = allowedOrigins;
  }

  read(): MaybePromise<PageSnapshot> {
    return this.page.readPage();
  }

  observed(snap: PageSnapshot): readonly string[] {
    return snap.texts;
  }

  /** Declared locator or URL; session node ids and coordinates never enter a result. */
  target(step: PagePlaybookStep): StepTarget {
    switch (step.kind) {
      case "goto":
        return urlTarget(step.url);
      case "click":
      case "fill":
      case "waitFor":
        return step.locator !== undefined && step.locator.length > 0 ? { kind: "locator", locator: step.locator } : { kind: "none" };
      case "read":
        return { kind: "none" };
      default: {
        const exhaustive: never = step.kind;
        throw new Error(`unhandled page step kind: ${String(exhaustive)}`);
      }
    }
  }

  classify(step: PagePlaybookStep): StepClass {
    return {
      permission: defaultPagePermission(step.kind),
      mutation: step.kind === "goto" || step.kind === "click" || step.kind === "fill",
    };
  }

  resolve(snap: PageSnapshot, step: PagePlaybookStep): Resolution<PageRef> {
    // `goto` is checked against its destination below; every other step must already be on a declared origin.
    if (step.kind !== "goto" && this.allowedOrigins !== undefined && !this.allowedOrigins.includes(originOf(snap.url))) {
      return unmet("origin_not_declared", `page origin ${originOf(snap.url)} is not declared`);
    }

    if (step.require?.url !== undefined && publicUrl(snap.url) !== publicUrl(step.require.url)) {
      return unmet("url_mismatch", `url ${publicUrl(snap.url)} !== ${publicUrl(step.require.url)}`);
    }

    const requiredTexts = step.require?.texts ?? [];
    const missingTexts = requiredTexts.filter(text => !snap.texts.includes(text));
    if (missingTexts.length > 0) return unmet("page_missing", `page missing ${missingTexts.join(", ")}`);

    const requiredLocators = step.require?.locators ?? [];
    const missingLocators = requiredLocators.filter(locator => !snap.locators.includes(locator));
    if (missingLocators.length > 0) return unmet("locator_not_on_page", `locator not on page: ${missingLocators.join(", ")}`);

    switch (step.kind) {
      case "read":
        return { ok: true, ref: { kind: "read" } };
      case "goto": {
        const url = step.url;
        if (url === undefined || url.length === 0) return unmet("url_required", "goto step url is required");
        const refusal = navigationRefusal(url, this.allowedOrigins);
        if (refusal !== null) return unmet("navigation_refused", refusal);
        return { ok: true, ref: { kind: "goto", url } };
      }
      case "click": {
        const locator = step.locator;
        if (locator === undefined || locator.length === 0) return unmet("locator_required", "step locator is required");
        if (!snap.locators.includes(locator)) return unmet("locator_not_on_page", `locator not on page: ${locator}`);
        return { ok: true, ref: { kind: "click", locator } };
      }
      case "fill": {
        const locator = step.locator;
        if (locator === undefined || locator.length === 0) return unmet("locator_required", "step locator is required");
        if (!snap.locators.includes(locator)) return unmet("locator_not_on_page", `locator not on page: ${locator}`);
        if (step.text === undefined) return unmet("text_required", "fill step text is required");
        return { ok: true, ref: { kind: "fill", locator, text: step.text } };
      }
      case "waitFor": {
        const locator = step.locator;
        if (locator === undefined || locator.length === 0) return unmet("locator_required", "step locator is required");
        return { ok: true, ref: { kind: "waitFor", locator } };
      }
      default: {
        const exhaustive: never = step.kind;
        throw new Error(`unhandled page step kind: ${String(exhaustive)}`);
      }
    }
  }

  act(_step: PagePlaybookStep, ref: PageRef): MaybePromise<void> {
    switch (ref.kind) {
      case "read":
        return undefined;
      case "goto":
        return this.page.goto(ref.url);
      case "click":
        return this.page.click(ref.locator);
      case "fill":
        return this.page.fill(ref.locator, ref.text);
      case "waitFor":
        return this.page.waitFor(ref.locator);
      default: {
        const exhaustive: never = ref;
        throw new Error(`unhandled ref: ${String(exhaustive)}`);
      }
    }
  }
}

export { publicUrl };

/**
 * Same rule as the Swift `browser_open` gate: an absolute, credential-free HTTP(S)
 * address — and, when the playbook declares origins, one of those.
 */
export function navigationRefusal(url: string, allowedOrigins?: readonly string[]): string | null {
  let parsed: URL;
  try {
    parsed = new URL(url);
  } catch {
    return "goto url is not absolute";
  }
  if (parsed.protocol !== "https:" && parsed.protocol !== "http:") return `goto scheme ${parsed.protocol} is refused`;
  if (parsed.username !== "" || parsed.password !== "") return "goto url carries credentials";
  if (allowedOrigins !== undefined && !allowedOrigins.includes(parsed.origin)) {
    return `goto origin ${parsed.origin} is not declared`;
  }
  return null;
}

/** Declared destination as origin + pathname; an unparsable or opaque URL is reported as no target (the step is refused anyway). */
function urlTarget(url: string | undefined): StepTarget {
  if (url === undefined || url.length === 0) return { kind: "none" };
  const publicForm = publicHttpUrl(url);
  return publicForm === null ? { kind: "none" } : { kind: "url", url: publicForm };
}

function unmet(code: RuntimeCode, detail: string): Resolution<never> {
  return { ok: false, code, detail };
}
