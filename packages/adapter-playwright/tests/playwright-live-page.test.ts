import assert from "node:assert/strict";
import { test } from "node:test";
import {
  LivePlaywrightPage,
  PlaywrightPageError,
  type PlaywrightLocatorHandle,
  type PlaywrightPageHandle,
} from "../src/index.ts";

test("LivePlaywrightPage maps goto, waitFor, and readPage onto a Playwright Page", async () => {
  const page = fakePage();
  const tools = new LivePlaywrightPage(page);

  assert.deepEqual(await tools.goto({ url: "https://example.com/" }), { url: "https://example.com/" });
  assert.deepEqual(await tools.waitFor({ locator: "h1" }), { visible: true });
  assert.deepEqual(await tools.readPage(), {
    url: "https://example.com/",
    title: "Example Domain",
    texts: ["Example Domain"],
    locators: ["h1"],
  });
  assert.deepEqual(page.gotoUrls, ["https://example.com/"]);
  assert.deepEqual(page.locatorMethods, [{ selector: "h1", method: "waitFor" }]);
});

test("LivePlaywrightPage maps click and fill onto page.locator", async () => {
  const page = fakePage();
  const tools = new LivePlaywrightPage(page);

  await tools.goto({ url: "https://example.com/" });
  assert.deepEqual(await tools.click({ locator: "#next" }), { clicked: true });
  assert.deepEqual(await tools.fill({ locator: "#name", text: "live" }), { filled: true });
  assert.deepEqual(page.locatorMethods, [
    { selector: "#next", method: "click" },
    { selector: "#name", method: "fill", text: "live" },
  ]);
});

test("missing live locator becomes PlaywrightPageError without launching a browser", async () => {
  const page = fakePage({ failWait: true });
  const tools = new LivePlaywrightPage(page);
  await assert.rejects(
    () => tools.waitFor({ locator: "#missing" }),
    error => error instanceof PlaywrightPageError && error.code === "locator_not_visible",
  );
});

function fakePage(options: { failWait?: boolean } = {}): PlaywrightPageHandle & {
  gotoUrls: string[];
  locatorMethods: Array<{ selector: string; method: string; text?: string }>;
} {
  let url = "about:blank";
  const gotoUrls: string[] = [];
  const locatorMethods: Array<{ selector: string; method: string; text?: string }> = [];

  const page = {
    gotoUrls,
    locatorMethods,
    async goto(next: string) {
      gotoUrls.push(next);
      url = next;
    },
    url() {
      return url;
    },
    async title() {
      return url.includes("example.com") ? "Example Domain" : "";
    },
    locator(selector: string): PlaywrightLocatorHandle {
      const locator: PlaywrightLocatorHandle = {
        async click() {
          locatorMethods.push({ selector, method: "click" });
        },
        async fill(text: string) {
          locatorMethods.push({ selector, method: "fill", text });
        },
        async waitFor() {
          if (options.failWait) throw new Error("Timeout");
          locatorMethods.push({ selector, method: "waitFor" });
        },
        async innerText() {
          return selector === "h1" ? "Example Domain" : "";
        },
        async count() {
          return selector === "h1" && url.includes("example.com") ? 1 : 0;
        },
        first() {
          return locator;
        },
      };
      return locator;
    },
  };
  return page;
}
