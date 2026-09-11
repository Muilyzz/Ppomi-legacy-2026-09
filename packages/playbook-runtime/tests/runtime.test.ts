import assert from "node:assert/strict";
import { test } from "node:test";
import {
  DummyAdapter,
  FixedPermissionGate,
  PlaybookRuntime,
  type Playbook,
  type ScreenSnapshot,
} from "../src/index.ts";

const screen: ScreenSnapshot = {
  title: "Demo App",
  texts: ["Demo App", "Next", "Name"],
  focused: null,
};

const happy: Playbook = {
  id: "fixture-happy",
  steps: [
    { id: "focus-app", kind: "focus", target: "Demo App" },
    { id: "open-next", kind: "click", target: "Next" },
    { id: "fill-name", kind: "type", target: "Name", text: "fixture" },
    { id: "confirm-screen", kind: "read", require: { screen: ["Demo App", "Next"] } },
  ],
};

test("happy path runs focus, click, type, and read against the dummy adapter", () => {
  const adapter = new DummyAdapter(screen);
  const runtime = new PlaybookRuntime(
    adapter,
    new FixedPermissionGate(["ui.read", "ui.control"]),
  );
  const result = runtime.run(happy);

  assert.equal(result.status, "completed");
  assert.equal(result.stopReason, null);
  assert.deepEqual(result.evidence.map(row => row.outcome), ["ok", "ok", "ok", "ok"]);
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

test("permission denied stops before any adapter call", () => {
  const adapter = new DummyAdapter(screen);
  const runtime = new PlaybookRuntime(adapter, new FixedPermissionGate(["ui.read"]));
  const result = runtime.run({
    id: "fixture-denied",
    steps: [
      { id: "open-next", kind: "click", target: "Next" },
      { id: "fill-name", kind: "type", target: "Name", text: "fixture" },
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

test("missing screen text stops without a mutation", () => {
  const adapter = new DummyAdapter(screen);
  const runtime = new PlaybookRuntime(
    adapter,
    new FixedPermissionGate(["ui.read", "ui.control"]),
  );
  const result = runtime.run({
    id: "fixture-screen",
    steps: [
      { id: "need-receipt", kind: "click", target: "Next", require: { screen: ["Receipt"] } },
      { id: "fill-name", kind: "type", target: "Name", text: "fixture" },
    ],
  });

  assert.equal(result.status, "stopped");
  assert.equal(result.stopReason, "precondition_failed");
  assert.equal(result.evidence[0]?.note, "screen missing Receipt");
  assert.deepEqual(adapter.calls, [{ kind: "read" }]);
});

test("missing target stops without a mutation", () => {
  const adapter = new DummyAdapter(screen);
  const runtime = new PlaybookRuntime(
    adapter,
    new FixedPermissionGate(["ui.read", "ui.control"]),
  );
  const result = runtime.run({
    id: "fixture-target",
    steps: [
      { id: "submit", kind: "click", target: "Submit" },
      { id: "fill-name", kind: "type", target: "Name", text: "fixture" },
    ],
  });

  assert.equal(result.status, "stopped");
  assert.equal(result.stopReason, "precondition_failed");
  assert.equal(result.evidence[0]?.note, "target not on screen: Submit");
  assert.deepEqual(adapter.calls, [{ kind: "read" }]);
});
