import type { PageSnapshot } from "../../playbook-runtime/src/index.ts";

/**
 * Playwright page methods this adapter may call.
 * Slice 1 uses an in-memory fixture. Live `page.goto` / locators are slice 2.
 * Not an OS / UIA / Accessibility surface and not a device-approval gate.
 */
export type PlaywrightPageToolName = "goto" | "click" | "fill" | "waitFor" | "readPage";

export interface PlaywrightPageNode {
  readonly locator: string;
  readonly text: string;
  readonly visible: boolean;
  readonly clickable: boolean;
  readonly fillable: boolean;
}

export interface PlaywrightPageTools {
  goto(args: { url: string }): { url: string };
  click(args: { locator: string }): { clicked: boolean };
  fill(args: { locator: string; text: string }): { filled: boolean };
  waitFor(args: { locator: string }): { visible: boolean };
  readPage(): PageSnapshot;
}

export class PlaywrightPageError extends Error {
  readonly code: string;

  constructor(code: string, message?: string) {
    super(message ?? code);
    this.name = "PlaywrightPageError";
    this.code = code;
  }
}
