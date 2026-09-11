import type { PageSnapshot } from "../../playbook-runtime/src/index.ts";

/**
 * Playwright page methods this adapter may call.
 * Fixture tools are sync. Live `page.goto` / locators return promises.
 * Local AI SDK tools (`createPlaywrightPageAiTools`) wrap these methods.
 * Not an OS / UIA / Accessibility surface and not a device-approval gate.
 */
export type PlaywrightPageToolName = "goto" | "click" | "fill" | "waitFor" | "readPage";

export type PlaywrightToolResult<T> = T | Promise<T>;

export interface PlaywrightPageNode {
  readonly locator: string;
  readonly text: string;
  readonly visible: boolean;
  readonly clickable: boolean;
  readonly fillable: boolean;
}

export interface PlaywrightPageTools {
  goto(args: { url: string }): PlaywrightToolResult<{ url: string }>;
  click(args: { locator: string }): PlaywrightToolResult<{ clicked: boolean }>;
  fill(args: { locator: string; text: string }): PlaywrightToolResult<{ filled: boolean }>;
  waitFor(args: { locator: string }): PlaywrightToolResult<{ visible: boolean }>;
  readPage(): PlaywrightToolResult<PageSnapshot>;
}

export class PlaywrightPageError extends Error {
  readonly code: string;

  constructor(code: string, message?: string) {
    super(message ?? code);
    this.name = "PlaywrightPageError";
    this.code = code;
  }
}
