import { jsonSchema, tool } from "ai";
import type { PlaywrightPageTools } from "./playwright-page-tools.ts";

/**
 * Local Vercel AI SDK tools for in-page Playwright (`goto` / `click` / `fill` / `waitFor` / `readPage`).
 * `execute` calls `PlaywrightPageTools` on this machine. Not a Vercel / cloud browser.
 * Not `OsAdapter` — native windows, cert UI, and system dialogs stay on
 * `adapter-windows` / `adapter-macos` (`readScreen` / `focus` / `click` / `type`).
 * See `../playbook-runtime/docs/adapter-selection.md`.
 */
export const playwrightPageAiToolNames = ["goto", "click", "fill", "waitFor", "readPage"] as const;

export type PlaywrightPageAiToolName = (typeof playwrightPageAiToolNames)[number];

const pageOnly =
  "In-page DOM on this machine via Playwright. Not OsAdapter (native windows, cert UI, UIA/AX). Not a Vercel / cloud browser.";

const urlInput = jsonSchema<{ url: string }>({
  type: "object",
  properties: {
    url: { type: "string", description: "Absolute http(s) URL to open in the local page." },
  },
  required: ["url"],
  additionalProperties: false,
});

const locatorInput = jsonSchema<{ locator: string }>({
  type: "object",
  properties: {
    locator: { type: "string", description: "In-page role, CSS, or text locator. Not a click coordinate." },
  },
  required: ["locator"],
  additionalProperties: false,
});

const fillInput = jsonSchema<{ locator: string; text: string }>({
  type: "object",
  properties: {
    locator: { type: "string", description: "In-page fillable locator. Not a click coordinate." },
    text: { type: "string", description: "Replacement text for the field." },
  },
  required: ["locator", "text"],
  additionalProperties: false,
});

const emptyInput = jsonSchema<Record<string, never>>({
  type: "object",
  properties: {},
  additionalProperties: false,
});

export function createPlaywrightPageAiTools(page: PlaywrightPageTools) {
  return {
    goto: tool({
      description: `${pageOnly} Navigate with page.goto.`,
      inputSchema: urlInput,
      execute: ({ url }) => page.goto({ url }),
    }),
    click: tool({
      description: `${pageOnly} Click an in-page control. Native / cert chrome uses OsAdapter.click.`,
      inputSchema: locatorInput,
      execute: ({ locator }) => page.click({ locator }),
    }),
    fill: tool({
      description: `${pageOnly} Fill an in-page field. Native / cert chrome uses OsAdapter.type.`,
      inputSchema: fillInput,
      execute: ({ locator, text }) => page.fill({ locator, text }),
    }),
    waitFor: tool({
      description: `${pageOnly} Wait until a locator is in the DOM. Do not wait for a native modal here — hand off to OsAdapter.readScreen first.`,
      inputSchema: locatorInput,
      execute: ({ locator }) => page.waitFor({ locator }),
    }),
    readPage: tool({
      description: `${pageOnly} Read url, title, visible text, and locators. Native screen text is OsAdapter.readScreen.`,
      inputSchema: emptyInput,
      execute: () => page.readPage(),
    }),
  };
}

export type PlaywrightPageAiTools = ReturnType<typeof createPlaywrightPageAiTools>;
