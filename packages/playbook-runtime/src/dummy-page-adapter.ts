import type { BrowserPageDriver, PageSnapshot } from "./browser-page-adapter.ts";

export type DummyPageCall =
  | { readonly kind: "read" }
  | { readonly kind: "goto"; readonly url: string }
  | { readonly kind: "click"; readonly locator: string }
  | { readonly kind: "fill"; readonly locator: string; readonly text: string }
  | { readonly kind: "waitFor"; readonly locator: string };

/** In-memory page adapter for unit tests. Not a live browser. Not `OsUiDriver`. */
export class DummyPageAdapter implements BrowserPageDriver {
  readonly calls: DummyPageCall[] = [];
  private page: PageSnapshot;

  constructor(page: PageSnapshot) {
    this.page = copyPage(page);
  }

  setPage(page: PageSnapshot): void {
    this.page = copyPage(page);
  }

  readPage(): PageSnapshot {
    this.calls.push({ kind: "read" });
    return copyPage(this.page);
  }

  goto(url: string): void {
    this.calls.push({ kind: "goto", url });
    this.page = { ...this.page, url };
  }

  click(locator: string): void {
    this.assertPresent(locator, "click");
    this.calls.push({ kind: "click", locator });
  }

  fill(locator: string, text: string): void {
    this.assertPresent(locator, "fill");
    this.calls.push({ kind: "fill", locator, text });
  }

  waitFor(locator: string): void {
    this.assertPresent(locator, "waitFor");
    this.calls.push({ kind: "waitFor", locator });
  }

  private assertPresent(locator: string, action: "click" | "fill" | "waitFor"): void {
    if (this.page.locators.includes(locator)) return;
    throw new Error(`dummy page adapter refused ${action}: locator not on page`);
  }
}

function copyPage(page: PageSnapshot): PageSnapshot {
  return {
    url: page.url,
    title: page.title,
    texts: [...page.texts],
    locators: [...page.locators],
  };
}
