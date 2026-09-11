import assert from "node:assert/strict";
import { test } from "node:test";
import {
  FixedPermissionGate,
  PagePlaybookRuntime,
  type PagePlaybook,
} from "../../playbook-runtime/src/index.ts";
import {
  FixturePlaywrightPage,
  PlaywrightPageAdapter,
  PlaywrightPageError,
  fixtureToolNames,
  type FixturePlaywrightDocument,
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

const smoke: PagePlaybook = {
  id: "fixture-playwright-smoke",
  steps: [
    { id: "open-form", kind: "goto", url: "https://example.test/form" },
    { id: "wait-next", kind: "waitFor", locator: "#next" },
    { id: "open-next", kind: "click", locator: "#next" },
    { id: "fill-name", kind: "fill", locator: "#name", text: "fixture" },
    { id: "confirm-page", kind: "read", require: { texts: ["Demo Page", "Next"] } },
  ],
};

const approvalTools = [
  "beginSignIn",
  "completeSignIn",
  "configureDevice",
  "refreshAccount",
  "signOut",
  "setControlApps",
];

test("smoke: PagePlaybookRuntime drives fixture Playwright tools through adapter-playwright", () => {
  const tools = new FixturePlaywrightPage(documents);
  const adapter = new PlaywrightPageAdapter(tools);
  const runtime = new PagePlaybookRuntime(
    adapter,
    new FixedPermissionGate(["ui.read", "ui.control"]),
  );
  const result = runtime.run(smoke);

  assert.equal(result.status, "completed");
  assert.equal(result.stopReason, null);
  assert.deepEqual(result.evidence.map(row => row.outcome), ["ok", "ok", "ok", "ok", "ok"]);
  assert.deepEqual(fixtureToolNames(tools.calls), [
    "readPage",
    "goto",
    "readPage",
    "waitFor",
    "readPage",
    "click",
    "readPage",
    "fill",
    "readPage",
  ]);
  assert.deepEqual(tools.calls.filter(call => call.name === "goto"), [
    { name: "goto", args: { url: "https://example.test/form" } },
  ]);
  assert.deepEqual(tools.calls.filter(call => call.name === "click"), [
    { name: "click", args: { locator: "#next" } },
  ]);
  assert.deepEqual(tools.calls.filter(call => call.name === "fill"), [
    { name: "fill", args: { locator: "#name", text: "fixture" } },
  ]);
  assert.equal(tools.calls.some(call => approvalTools.includes(call.name)), false);
  assert.doesNotMatch(JSON.stringify(result), /approv/i);
  assert.equal("deviceApproved" in result, false);
  assert.equal("readScreen" in adapter, false);
  assert.equal("focus" in adapter, false);
});

test("missing click locator does not call click", () => {
  const tools = new FixturePlaywrightPage(documents);
  const adapter = new PlaywrightPageAdapter(tools);
  adapter.readPage();
  assert.throws(() => adapter.click("#submit"), error =>
    error instanceof PlaywrightPageError && error.code === "locator_not_on_page");
  assert.deepEqual(fixtureToolNames(tools.calls), ["readPage"]);
});

test("goto switches the in-memory document before later locators resolve", () => {
  const tools = new FixturePlaywrightPage(documents);
  const adapter = new PlaywrightPageAdapter(tools);
  assert.equal(adapter.readPage().url, "https://example.test/start");
  adapter.goto("https://example.test/form");
  assert.deepEqual(adapter.readPage().locators, ["#next", "#name"]);
  adapter.click("#next");
  assert.deepEqual(fixtureToolNames(tools.calls), ["readPage", "goto", "readPage", "click"]);
});
