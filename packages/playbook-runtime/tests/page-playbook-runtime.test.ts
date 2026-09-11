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
    { id: "open-form", kind: "goto", url: "https://example.test/form" },
    { id: "wait-next", kind: "waitFor", locator: "#next" },
    { id: "open-next", kind: "click", locator: "#next" },
    { id: "fill-name", kind: "fill", locator: "#name", text: "fixture" },
    { id: "confirm-page", kind: "read", require: { texts: ["Demo Page", "Next"] } },
  ],
};

test("happy path runs goto, waitFor, click, fill, and read against the dummy page adapter", () => {
  const adapter = new DummyPageAdapter(page);
  const runtime = new PagePlaybookRuntime(
    adapter,
    new FixedPermissionGate(["ui.read", "ui.control"]),
  );
  const result = runtime.run(happy);

  assert.equal(result.status, "completed");
  assert.equal(result.stopReason, null);
  assert.deepEqual(result.evidence.map(row => row.outcome), ["ok", "ok", "ok", "ok", "ok"]);
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

test("page permission denied stops before any adapter call", () => {
  const adapter = new DummyPageAdapter(page);
  const runtime = new PagePlaybookRuntime(adapter, new FixedPermissionGate(["ui.read"]));
  const result = runtime.run({
    id: "fixture-page-denied",
    steps: [
      { id: "open-next", kind: "click", locator: "#next" },
      { id: "fill-name", kind: "fill", locator: "#name", text: "fixture" },
    ],
  });

  assert.equal(result.status, "stopped");
  assert.equal(result.stopReason, "permission_denied");
  assert.deepEqual(result.evidence, [{
    stepId: "open-next",
    kind: "click",
    outcome: "permission_denied",
    screenTexts: [],
    note: "missing permission ui.control",
  }]);
  assert.deepEqual(adapter.calls, []);
});

test("missing page text stops without a mutation", () => {
  const adapter = new DummyPageAdapter(page);
  const runtime = new PagePlaybookRuntime(
    adapter,
    new FixedPermissionGate(["ui.read", "ui.control"]),
  );
  const result = runtime.run({
    id: "fixture-page-texts",
    steps: [
      { id: "need-receipt", kind: "click", locator: "#next", require: { texts: ["Receipt"] } },
      { id: "fill-name", kind: "fill", locator: "#name", text: "fixture" },
    ],
  });

  assert.equal(result.status, "stopped");
  assert.equal(result.stopReason, "precondition_failed");
  assert.equal(result.evidence[0]?.note, "page missing Receipt");
  assert.deepEqual(adapter.calls, [{ kind: "read" }]);
});

test("missing click locator stops without a mutation", () => {
  const adapter = new DummyPageAdapter(page);
  const runtime = new PagePlaybookRuntime(
    adapter,
    new FixedPermissionGate(["ui.read", "ui.control"]),
  );
  const result = runtime.run({
    id: "fixture-page-locator",
    steps: [
      { id: "submit", kind: "click", locator: "#submit" },
      { id: "fill-name", kind: "fill", locator: "#name", text: "fixture" },
    ],
  });

  assert.equal(result.status, "stopped");
  assert.equal(result.stopReason, "precondition_failed");
  assert.equal(result.evidence[0]?.note, "locator not on page: #submit");
  assert.deepEqual(adapter.calls, [{ kind: "read" }]);
});

test("page step permissions are ui.read and ui.control only; a run has no device-approval gate", () => {
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
  const result = runtime.run({
    id: "fixture-page-no-device-gate",
    steps: [{ id: "open-next", kind: "click", locator: "#next" }],
  });

  assert.equal(result.status, "completed");
  assert.equal(result.stopReason, null);
  assert.equal("deviceApproved" in result, false);
  assert.equal("approved" in result, false);
  assert.match(JSON.stringify(result), /"outcome":"ok"/);
  assert.doesNotMatch(JSON.stringify(result), /approv/i);
});
