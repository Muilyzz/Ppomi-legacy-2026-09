import type { BrowserPageAdapter, PageSnapshot } from "../../playbook-runtime/src/index.ts";
import type { PlaywrightPageTools } from "./playwright-page-tools.ts";
import { PlaywrightPageError } from "./playwright-page-tools.ts";

/**
 * `BrowserPageAdapter` over Playwright page tools (`goto` / `click` / `fill` / `waitFor`).
 * Sync fixture tools only — it does not await `LivePlaywrightPage`.
 * Does not launch a browser itself and has no device-approval input.
 * Not `OsAdapter` — native/cert dialogs stay on `adapter-windows` / `adapter-macos`.
 */
export class PlaywrightPageAdapter implements BrowserPageAdapter {
  private readonly tools: PlaywrightPageTools;
  private lastPage: PageSnapshot | null = null;

  constructor(tools: PlaywrightPageTools) {
    this.tools = tools;
  }

  readPage(): PageSnapshot {
    this.lastPage = this.tools.readPage();
    return this.lastPage;
  }

  goto(url: string): void {
    this.tools.goto({ url });
    this.lastPage = null;
  }

  click(locator: string): void {
    this.requireLocator(locator);
    this.tools.click({ locator });
    this.lastPage = null;
  }

  fill(locator: string, text: string): void {
    this.requireLocator(locator);
    this.tools.fill({ locator, text });
    this.lastPage = null;
  }

  waitFor(locator: string): void {
    this.tools.waitFor({ locator });
    this.lastPage = null;
  }

  private requireLocator(locator: string): PageSnapshot {
    const page = this.lastPage ?? this.tools.readPage();
    this.lastPage = page;
    if (!page.locators.includes(locator)) {
      throw new PlaywrightPageError("locator_not_on_page", `locator not on page: ${locator}`);
    }
    return page;
  }
}
