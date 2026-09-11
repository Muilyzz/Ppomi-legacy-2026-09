import type { MaybePromise } from "./playbook.ts";

/**
 * In-page web port (`PageSurface`). `adapter-playwright` implements it. Not
 * `OsAdapter`. Sync adapters still satisfy it: the runtime awaits every call.
 * No device-approval input.
 */
export interface PageSnapshot {
  readonly url: string;
  readonly title: string;
  readonly texts: readonly string[];
  readonly locators: readonly string[];
}

export interface BrowserPageAdapter {
  readPage(): MaybePromise<PageSnapshot>;
  goto(url: string): MaybePromise<void>;
  click(locator: string): MaybePromise<void>;
  fill(locator: string, text: string): MaybePromise<void>;
  waitFor(locator: string): MaybePromise<void>;
}
