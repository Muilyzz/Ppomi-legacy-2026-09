/** In-page web port. `adapter-playwright` implements this. Not `OsAdapter`. No device-approval input. */
export interface PageSnapshot {
  readonly url: string;
  readonly title: string;
  readonly texts: readonly string[];
  readonly locators: readonly string[];
}

export interface BrowserPageAdapter {
  readPage(): PageSnapshot;
  goto(url: string): void;
  click(locator: string): void;
  fill(locator: string, text: string): void;
  waitFor(locator: string): void;
}
