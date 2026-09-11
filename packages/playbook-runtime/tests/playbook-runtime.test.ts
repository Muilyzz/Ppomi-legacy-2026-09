import assert from "node:assert/strict";
import { test } from "node:test";
import {
  DummyAdapter,
  FixedPermissionGate,
  PlaybookRuntime,
  defaultPermission,
  type Playbook,
  type ScreenSnapshot,
  type StepKind,
} from "../src/index.ts";

const screen: ScreenSnapshot = {
  title: "Demo App",
  texts: ["Demo App", "Next", "Name"],
  focused: null,
};

const happy: Playbook = {
  id: "fixture-happy",
  steps: [
    { id: "focus-app", kind: "focus", target: "Demo App", effect: "navigate" },
    { id: "open-next", kind: "click", target: "Next", effect: "navigate" },
    { id: "fill-name", kind: "type", target: "Name", text: "fixture", effect: "input" },
    { id: "confirm-screen", kind: "read", require: { screen: ["Demo App", "Next"] } },
  ],
};

test("happy path runs focus, click, type, and read against the dummy adapter", async () => {
  const adapter = new DummyAdapter(screen);
  const runtime = new PlaybookRuntime(
    adapter,
    new FixedPermissionGate(["ui.read", "ui.control"]),
  );
  const result = await runtime.run(happy);

  assert.equal(result.status, "completed");
  assert.equal(result.stopReason, null);
  assert.deepEqual(result.evidence.map(row => row.status), ["done", "done", "done", "done"]);
  assert.deepEqual(result.evidence.map(row => row.surface), ["os", "os", "os", "os"]);
  assert.deepEqual(adapter.calls, [
    { kind: "read" },
    { kind: "focus", target: "Demo App" },
    { kind: "read" },
    { kind: "click", target: "Next" },
    { kind: "read" },
    { kind: "type", target: "Name", text: "fixture" },
    { kind: "read" },
  ]);
});

test("permission denied stops before any adapter call", async () => {
  const adapter = new DummyAdapter(screen);
  const runtime = new PlaybookRuntime(adapter, new FixedPermissionGate(["ui.read"]), { now: () => 1_700_000_000_000 });
  const result = await runtime.run({
    id: "fixture-denied",
    steps: [
      { id: "open-next", kind: "click", target: "Next", effect: "navigate" },
      { id: "fill-name", kind: "type", target: "Name", text: "fixture", effect: "input" },
    ],
  });

  assert.equal(result.status, "stopped");
  assert.equal(result.stopReason, "refused");
  assert.deepEqual(result.evidence, [{
    stepId: "open-next",
    kind: "click",
    surface: "os",
    status: "refused",
    code: "missing_permission",
    url: null,
    at: 1_700_000_000_000,
    detail: "missing permission ui.control",
  }]);
  assert.deepEqual(result.observed, []);
  assert.deepEqual(adapter.calls, []);
});

test("missing screen text stops without a mutation", async () => {
  const adapter = new DummyAdapter(screen);
  const runtime = new PlaybookRuntime(
    adapter,
    new FixedPermissionGate(["ui.read", "ui.control"]),
  );
  const result = await runtime.run({
    id: "fixture-screen",
    steps: [
      { id: "need-receipt", kind: "click", target: "Next", effect: "navigate", require: { screen: ["Receipt"] } },
      { id: "fill-name", kind: "type", target: "Name", text: "fixture", effect: "input" },
    ],
  });

  assert.equal(result.status, "stopped");
  assert.equal(result.stopReason, "unmet");
  assert.equal(result.evidence[0]?.detail, "screen missing Receipt");
  assert.deepEqual(adapter.calls, [{ kind: "read" }]);
});

test("step permissions are ui.read and ui.control only; a run has no device-approval gate", async () => {
  const kinds: StepKind[] = ["read", "focus", "click", "type"];
  assert.deepEqual(kinds.map(defaultPermission), [
    "ui.read",
    "ui.control",
    "ui.control",
    "ui.control",
  ]);

  const adapter = new DummyAdapter(screen);
  const runtime = new PlaybookRuntime(
    adapter,
    new FixedPermissionGate(["ui.read", "ui.control"]),
  );
  const result = await runtime.run({
    id: "fixture-no-device-gate",
    steps: [{ id: "open-next", kind: "click", target: "Next", effect: "navigate" }],
  });

  assert.equal(result.status, "completed");
  assert.equal(result.stopReason, null);
  assert.equal("deviceApproved" in result, false);
  assert.equal("approved" in result, false);
  assert.match(JSON.stringify(result), /"status":"done"/);
  assert.doesNotMatch(JSON.stringify(result), /approv/i);
});

test("missing target stops without a mutation", async () => {
  const adapter = new DummyAdapter(screen);
  const runtime = new PlaybookRuntime(
    adapter,
    new FixedPermissionGate(["ui.read", "ui.control"]),
  );
  const result = await runtime.run({
    id: "fixture-target",
    steps: [
      { id: "submit", kind: "click", target: "Submit", effect: "navigate" },
      { id: "fill-name", kind: "type", target: "Name", text: "fixture", effect: "input" },
    ],
  });

  assert.equal(result.status, "stopped");
  assert.equal(result.stopReason, "unmet");
  assert.equal(result.evidence[0]?.detail, "target not on screen: Submit");
  assert.deepEqual(adapter.calls, [{ kind: "read" }]);
});
