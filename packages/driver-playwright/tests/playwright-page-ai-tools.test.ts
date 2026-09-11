import assert from "node:assert/strict";
import { test } from "node:test";
import {
  FixturePlaywrightPage,
  LivePlaywrightPage,
  PlaywrightPageError,
  createPlaywrightPageAiTools,
  fixtureToolNames,
  playwrightPageAiToolNames,
  type FixturePlaywrightDocument,
  type PlaywrightLocatorHandle,
  type PlaywrightPageHandle,
  type PlaywrightPageAiTools,
} from "../src/index.ts";

const documents: readonly FixturePlaywrightDocument[] = [
  {
    url: "https://example.test/start",
    title: "Start",
    nodes: [{ locator: "#open", text: "Open", clickable: true, fillable: false }],
  },
  {
    url: "https://example.test/form",
    title: "Demo Page",
    nodes: [
      { locator: "#next", text: "Next", clickable: true, fillable: false },
      { locator: "#name", text: "Name", clickable: false, fillable: true },
    ],
  },
];

const osToolNames = ["readScreen", "focus", "type", "ui_tap", "ui_type", "screen_read"] as const;
const exec = { toolCallId: "fixture", messages: [] };

async function run<T>(tools: PlaywrightPageAiTools, name: keyof PlaywrightPageAiTools, input: unknown): Promise<T> {
  const item = tools[name];
  assert.equal(typeof item.execute, "function");
  return await item.execute!(input as never, exec as never) as T;
}

test("createPlaywrightPageAiTools exposes only in-page operations", () => {
  const tools = createPlaywrightPageAiTools(new FixturePlaywrightPage(documents));
  assert.deepEqual(Object.keys(tools).sort(), [...playwrightPageAiToolNames].sort());
  for (const name of osToolNames) {
    assert.equal(name in tools, false, name);
  }
  for (const name of playwrightPageAiToolNames) {
    const description = tools[name]?.description ?? "";
    assert.match(description, /in-page/i);
    assert.match(description, /OsUiDriver/);
    assert.match(description, /not a Vercel \/ cloud browser/i);
  }
});

test("AI SDK tools drive fixture Playwright page methods", async () => {
  const page = new FixturePlaywrightPage(documents);
  const tools = createPlaywrightPageAiTools(page);

  assert.deepEqual(await run(tools, "readPage", {}), {
    url: "https://example.test/start",
    title: "Start",
    texts: ["Start", "Open"],
    locators: ["#open"],
  });
  assert.deepEqual(await run(tools, "goto", { url: "https://example.test/form" }), {
    url: "https://example.test/form",
  });
  assert.deepEqual(await run(tools, "waitFor", { locator: "#next" }), { visible: true });
  assert.deepEqual(await run(tools, "click", { locator: "#next" }), { clicked: true });
  assert.deepEqual(await run(tools, "fill", { locator: "#name", text: "fixture" }), { filled: true });
  assert.deepEqual(await run(tools, "readPage", {}), {
    url: "https://example.test/form",
    title: "Demo Page",
    texts: ["Demo Page", "Next", "Name"],
    locators: ["#next", "#name"],
  });
  assert.deepEqual(fixtureToolNames(page.calls), [
    "readPage",
    "goto",
    "waitFor",
    "click",
    "fill",
    "readPage",
  ]);
  assert.equal(page.calls.some(call => osToolNames.includes(call.name as (typeof osToolNames)[number])), false);
});

test("AI SDK click on a missing locator does not invent an OS step", async () => {
  const page = new FixturePlaywrightPage(documents);
  const tools = createPlaywrightPageAiTools(page);
  await assert.rejects(
    () => run(tools, "click", { locator: "#missing" }),
    error => error instanceof PlaywrightPageError && error.code === "locator_not_on_page",
  );
  assert.deepEqual(fixtureToolNames(page.calls), ["click"]);
  assert.equal("readScreen" in tools, false);
});

test("AI SDK tools await LivePlaywrightPage without launching a browser", async () => {
  const handle = fakePage();
  const tools = createPlaywrightPageAiTools(new LivePlaywrightPage(handle));

  assert.deepEqual(await run(tools, "goto", { url: "https://example.com/" }), { url: "https://example.com/" });
  assert.deepEqual(await run(tools, "waitFor", { locator: "h1" }), { visible: true });
  assert.deepEqual(await run(tools, "click", { locator: "#next" }), { clicked: true });
  assert.deepEqual(await run(tools, "fill", { locator: "#name", text: "live" }), { filled: true });
  assert.deepEqual(await run(tools, "readPage", {}), {
    url: "https://example.com/",
    title: "Example Domain",
    texts: ["Example Domain"],
    locators: ["h1"],
  });
  assert.deepEqual(handle.gotoUrls, ["https://example.com/"]);
  assert.deepEqual(handle.locatorMethods, [
    { selector: "h1", method: "waitFor" },
    { selector: "#next", method: "click" },
    { selector: "#name", method: "fill", text: "live" },
  ]);
});

function fakePage(): PlaywrightPageHandle & {
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
