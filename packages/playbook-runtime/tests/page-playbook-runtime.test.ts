import assert from "node:assert/strict";
import { test } from "node:test";
import {
  DummyPageAdapter,
  FixedPermissionGate,
  PagePlaybookRuntime,
  defaultPagePermission,
  type PagePlaybook,
  type PageSnapshot,
  type PageStepKind,
} from "../src/index.ts";

const page: PageSnapshot = {
  url: "https://example.test/start",
  title: "Demo Page",
  texts: ["Demo Page", "Next", "Name"],
  locators: ["#next", "#name"],
};

const happy: PagePlaybook = {
  id: "fixture-page-happy",
  steps: [
    { id: "open-form", kind: "goto", url: "https://example.test/form", effect: "navigate" },
    { id: "wait-next", kind: "waitFor", locator: "#next" },
    { id: "open-next", kind: "click", locator: "#next", effect: "navigate" },
    { id: "fill-name", kind: "fill", locator: "#name", text: "fixture", effect: "input" },
    { id: "confirm-page", kind: "read", require: { texts: ["Demo Page", "Next"] } },
  ],
};

test("happy path runs goto, waitFor, click, fill, and read against the dummy page adapter", async () => {
  const adapter = new DummyPageAdapter(page);
  const runtime = new PagePlaybookRuntime(
    adapter,
    new FixedPermissionGate(["ui.read", "ui.control"]),
  );
  const result = await runtime.run(happy);

  assert.equal(result.status, "completed");
  assert.equal(result.stopReason, null);
  assert.deepEqual(result.evidence.map(row => row.status), ["done", "done", "done", "done", "done"]);
  assert.deepEqual(result.evidence.map(row => row.surface), ["page", "page", "page", "page", "page"]);
  assert.deepEqual(adapter.calls, [
    { kind: "read" },
    { kind: "goto", url: "https://example.test/form" },
    { kind: "read" },
    { kind: "waitFor", locator: "#next" },
    { kind: "read" },
    { kind: "click", locator: "#next" },
    { kind: "read" },
    { kind: "fill", locator: "#name", text: "fixture" },
    { kind: "read" },
  ]);
});

test("page permission denied stops before any adapter call", async () => {
  const adapter = new DummyPageAdapter(page);
  const runtime = new PagePlaybookRuntime(adapter, new FixedPermissionGate(["ui.read"]), { now: () => 1_700_000_000_000 });
  const result = await runtime.run({
    id: "fixture-page-denied",
    steps: [
      { id: "open-next", kind: "click", locator: "#next", effect: "navigate" },
      { id: "fill-name", kind: "fill", locator: "#name", text: "fixture", effect: "input" },
    ],
  });

  assert.equal(result.status, "stopped");
  assert.equal(result.stopReason, "refused");
  assert.deepEqual(result.evidence, [{
    stepId: "open-next",
    kind: "click",
    surface: "page",
    status: "refused",
    code: "missing_permission",
    url: null,
    at: 1_700_000_000_000,
    detail: "missing permission ui.control",
  }]);
  assert.deepEqual(result.observed, []);
  assert.deepEqual(adapter.calls, []);
});

test("missing page text stops without a mutation", async () => {
  const adapter = new DummyPageAdapter(page);
  const runtime = new PagePlaybookRuntime(
    adapter,
    new FixedPermissionGate(["ui.read", "ui.control"]),
  );
  const result = await runtime.run({
    id: "fixture-page-texts",
    steps: [
      { id: "need-receipt", kind: "click", locator: "#next", effect: "navigate", require: { texts: ["Receipt"] } },
      { id: "fill-name", kind: "fill", locator: "#name", text: "fixture", effect: "input" },
    ],
  });

  assert.equal(result.status, "stopped");
  assert.equal(result.stopReason, "unmet");
  assert.equal(result.evidence[0]?.detail, "page missing Receipt");
  assert.deepEqual(adapter.calls, [{ kind: "read" }]);
});

test("missing click locator stops without a mutation", async () => {
  const adapter = new DummyPageAdapter(page);
  const runtime = new PagePlaybookRuntime(
    adapter,
    new FixedPermissionGate(["ui.read", "ui.control"]),
  );
  const result = await runtime.run({
    id: "fixture-page-locator",
    steps: [
      { id: "submit", kind: "click", locator: "#submit", effect: "navigate" },
      { id: "fill-name", kind: "fill", locator: "#name", text: "fixture", effect: "input" },
    ],
  });

  assert.equal(result.status, "stopped");
  assert.equal(result.stopReason, "unmet");
  assert.equal(result.evidence[0]?.detail, "locator not on page: #submit");
  assert.deepEqual(adapter.calls, [{ kind: "read" }]);
});

test("page step permissions are ui.read and ui.control only; a run has no device-approval gate", async () => {
  const kinds: PageStepKind[] = ["read", "waitFor", "goto", "click", "fill"];
  assert.deepEqual(kinds.map(defaultPagePermission), [
    "ui.read",
    "ui.read",
    "ui.control",
    "ui.control",
    "ui.control",
  ]);

  const adapter = new DummyPageAdapter(page);
  const runtime = new PagePlaybookRuntime(
    adapter,
    new FixedPermissionGate(["ui.read", "ui.control"]),
  );
  const result = await runtime.run({
    id: "fixture-page-no-device-gate",
    steps: [{ id: "open-next", kind: "click", locator: "#next", effect: "navigate" }],
  });

  assert.equal(result.status, "completed");
  assert.equal(result.stopReason, null);
  assert.equal("deviceApproved" in result, false);
  assert.equal("approved" in result, false);
  assert.match(JSON.stringify(result), /"status":"done"/);
  assert.doesNotMatch(JSON.stringify(result), /approv/i);
});
