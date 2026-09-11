import type { PageSnapshot } from "../../playbook-runtime/src/index.ts";
import type { PlaywrightPageTools } from "./playwright-page-tools.ts";
import { PlaywrightPageError } from "./playwright-page-tools.ts";

/**
 * Playwright `Page` / `Locator` surface this live tool calls.
 * A real Playwright `Page` satisfies this. Tests pass an in-memory fake.
 */
export interface PlaywrightPageHandle {
  goto(url: string): Promise<unknown>;
  url(): string;
  title(): Promise<string>;
  locator(selector: string): PlaywrightLocatorHandle;
}

export interface PlaywrightLocatorHandle {
  click(): Promise<unknown>;
  fill(text: string): Promise<unknown>;
  waitFor(): Promise<unknown>;
  innerText(): Promise<string>;
  count(): Promise<number>;
  first(): PlaywrightLocatorHandle;
}

/**
 * `PlaywrightPageTools` over a real Playwright `Page`.
 * Does not launch a browser. Device-local Chromium is opened by the live script.
 * Not `OsAdapter` and not a Vercel / cloud browser client.
 * Do not `waitFor` a locator that only appears after a native modal; hand off to OS first.
 * See `../playbook-runtime/docs/adapter-selection.md`.
 */
export class LivePlaywrightPage implements PlaywrightPageTools {
  private readonly page: PlaywrightPageHandle;

  constructor(page: PlaywrightPageHandle) {
    this.page = page;
  }

  async goto(args: { url: string }): Promise<{ url: string }> {
    try {
      await this.page.goto(args.url);
    } catch (error) {
      throw wrap(error, "navigation_failed", `goto failed: ${args.url}`);
    }
    return { url: this.page.url() };
  }

  async click(args: { locator: string }): Promise<{ clicked: boolean }> {
    try {
      await this.page.locator(args.locator).click();
    } catch (error) {
      throw wrap(error, "locator_not_clickable", `click failed: ${args.locator}`);
    }
    return { clicked: true };
  }

  async fill(args: { locator: string; text: string }): Promise<{ filled: boolean }> {
    try {
      await this.page.locator(args.locator).fill(args.text);
    } catch (error) {
      throw wrap(error, "locator_not_fillable", `fill failed: ${args.locator}`);
    }
    return { filled: true };
  }

  async waitFor(args: { locator: string }): Promise<{ visible: boolean }> {
    try {
      await this.page.locator(args.locator).waitFor();
    } catch (error) {
      throw wrap(error, "locator_not_visible", `locator not visible: ${args.locator}`);
    }
    return { visible: true };
  }

  async readPage(): Promise<PageSnapshot> {
    const url = this.page.url();
    const title = await this.page.title();
    const heading = this.page.locator("h1");
    const texts = uniqueTexts([title]);
    const locators: string[] = [];
    if (await heading.count() > 0) {
      locators.push("h1");
      const headingText = (await heading.first().innerText()).trim();
      if (headingText.length > 0 && !texts.includes(headingText)) texts.push(headingText);
    }
    return { url, title, texts, locators };
  }
}

function wrap(error: unknown, code: string, fallback: string): PlaywrightPageError {
  if (error instanceof PlaywrightPageError) return error;
  const message = error instanceof Error && error.message.length > 0 ? error.message : fallback;
  return new PlaywrightPageError(code, message);
}

function uniqueTexts(values: readonly string[]): string[] {
  const texts: string[] = [];
  for (const value of values) {
    const text = value.trim();
    if (text.length === 0 || texts.includes(text)) continue;
    texts.push(text);
  }
  return texts;
}
