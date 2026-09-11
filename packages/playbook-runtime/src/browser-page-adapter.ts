/** In-page web port (`PagePlaybookRuntime`, `driver-playwright`). Not `OsUiDriver`. See `docs/adapter-selection.md`. No device-approval input. */
export interface PageSnapshot {
  readonly url: string;
  readonly title: string;
  readonly texts: readonly string[];
  readonly locators: readonly string[];
}

export interface BrowserPageDriver {
  readPage(): PageSnapshot;
  goto(url: string): void;
  click(locator: string): void;
  fill(locator: string, text: string): void;
  waitFor(locator: string): void;
}
