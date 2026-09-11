import assert from "node:assert/strict";
import { test } from "node:test";
import {
  AdapterTimeoutError,
  DummyAdapter,
  FixedPermissionGate,
  PlaybookRuntime,
  defaultPermission,
  dumpStepResults,
  parseStepResultsJson,
  type OsAdapter,
  type Playbook,
  type ScreenSnapshot,
  type StepKind,
  type StepResult,
} from "../src/index.ts";

const screen: ScreenSnapshot = {
  title: "Demo App",
  texts: ["Demo App", "Next", "Name"],
  focused: null,
};

// Differs from #18: mutations declare their effect (focus has an implied navigate), as the core requires.
const happy: Playbook = {
  id: "fixture-happy",
  steps: [
    { id: "focus-app", kind: "focus", target: "Demo App" },
    { id: "open-next", kind: "click", target: "Next", effect: "navigate" },
    { id: "fill-name", kind: "type", target: "Name", text: "fixture", effect: "input" },
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
  assert.deepEqual(result.stepResults.map(row => row.status), ["ok", "ok", "ok", "ok"]);
  assert.deepEqual(result.stepResults.map(row => row.attempt), [
    "executed",
    "executed",
    "executed",
    "executed",
  ]);
  assert.deepEqual(result.stepResults.map(row => row.action), ["focus", "click", "type", "read"]);
  assert.deepEqual(result.stepResults[0]?.target, { kind: "accessibility", name: "Demo App" });
  assert.equal(result.stepResults[0]?.driver, "os-windows");
  assert.equal(result.stepResults[0]?.playbookId, "fixture-happy");
  assert.deepEqual(parseStepResultsJson(dumpStepResults(result.stepResults)), result.stepResults);
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
      { id: "open-next", kind: "click", target: "Next", effect: "navigate" },
      { id: "fill-name", kind: "type", target: "Name", text: "fixture", effect: "input" },
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
  assertOsStepResults(result.stepResults, "os-windows", [
    {
      // Differs from #18: a plain permission stop is failed (code permission_denied);
      // protected is reserved for the driver's protected-control refusal (protected_action).
      stepId: "open-next",
      status: "failed",
      attempt: "not_executed",
      summary: "missing permission ui.control",
      target: { kind: "accessibility", name: "Next" },
    },
    {
      stepId: "fill-name",
      status: "failed",
      attempt: "not_executed",
      summary: "previous step stopped the run; adapter was not called",
      target: { kind: "accessibility", name: "Name" },
    },
  ]);
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
      { id: "need-receipt", kind: "click", target: "Next", effect: "navigate", require: { screen: ["Receipt"] } },
      { id: "fill-name", kind: "type", target: "Name", text: "fixture", effect: "input" },
    ],
  });

  assert.equal(result.status, "stopped");
  assert.equal(result.stopReason, "precondition_failed");
  assert.equal(result.evidence[0]?.note, "screen missing Receipt");
  assert.deepEqual(adapter.calls, [{ kind: "read" }]);
  assert.equal(result.stepResults[0]?.attempt, "not_executed");
  assert.equal(result.stepResults[0]?.status, "failed");
  assert.equal(result.stepResults[1]?.attempt, "not_executed");
});

test("step permissions are ui.read and ui.control only; a run has no device-approval gate", () => {
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
  const result = runtime.run({
    id: "fixture-no-device-gate",
    steps: [{ id: "open-next", kind: "click", target: "Next", effect: "navigate" }],
  });

  assert.equal(result.status, "completed");
  assert.equal(result.stopReason, null);
  assert.equal("deviceApproved" in result, false);
  assert.equal("approved" in result, false);
  assert.match(JSON.stringify(result), /"outcome":"ok"/);
  assert.doesNotMatch(JSON.stringify(result), /approv/i);
  assert.equal(result.stepResults[0]?.driver, "os-windows");
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
      { id: "submit", kind: "click", target: "Submit", effect: "navigate" },
      { id: "fill-name", kind: "type", target: "Name", text: "fixture", effect: "input" },
    ],
  });

  assert.equal(result.status, "stopped");
  assert.equal(result.stopReason, "precondition_failed");
  assert.equal(result.evidence[0]?.note, "target not on screen: Submit");
  assert.deepEqual(adapter.calls, [{ kind: "read" }]);
  assert.equal(result.stepResults[0]?.attempt, "not_executed");
  assert.equal(result.stepResults[1]?.attempt, "not_executed");
});

// Differs from #18: rows carry `driver` (the #22 name); `adapter` is only an input alias of the parser.
test("injected OsAdapter.kind is copied onto each StepResult", () => {
  const adapter = new DummyAdapter(screen, "os-macos");
  const runtime = new PlaybookRuntime(
    adapter,
    new FixedPermissionGate(["ui.read", "ui.control"]),
  );
  const result = runtime.run({
    id: "fixture-macos",
    steps: [{ id: "confirm", kind: "focus", target: "Demo App" }],
  });

  assert.equal(result.status, "completed");
  assert.equal(result.stepResults[0]?.driver, "os-macos");
  assert.equal(adapter.kind, "os-macos");
});

test("OS click timeout is attempt timeout, later click is not_executed", () => {
  const adapter = new TimeoutClickAdapter({
    ...screen,
    texts: ["Demo App", "Next", "Name", "인증서"],
  });
  const runtime = new PlaybookRuntime(
    adapter,
    new FixedPermissionGate(["ui.read", "ui.control"]),
  );
  const result = runtime.run({
    id: "fixture-hybrid",
    steps: [
      { id: "wait-cert", kind: "click", target: "인증서", effect: "navigate" },
      { id: "sign", kind: "click", target: "Next", effect: "commit" },
    ],
  });

  assert.equal(result.status, "stopped");
  assert.equal(result.stopReason, "timeout");
  assert.equal(result.evidence[0]?.outcome, "timeout");
  assert.deepEqual(adapter.calls, [{ kind: "read" }, { kind: "click", target: "인증서" }]);
  // Differs from #18: a timed-out click may already have applied, so the core reports
  // needs_human instead of retryable (only reads / waitFor / focus / goto stay retryable).
  assertOsStepResults(result.stepResults, "os-windows", [
    {
      stepId: "wait-cert",
      status: "needs_human",
      attempt: "timeout",
      summary: "click timed out waiting for 인증서",
      target: { kind: "accessibility", name: "인증서" },
    },
    {
      stepId: "sign",
      status: "failed",
      attempt: "not_executed",
      summary: "previous step stopped the run; adapter was not called",
      target: { kind: "accessibility", name: "Next" },
    },
  ]);
  assert.notEqual(result.stepResults[0]?.attempt, result.stepResults[1]?.attempt);
});

class TimeoutClickAdapter implements OsAdapter {
  readonly kind = "os-windows" as const;
  readonly calls: Array<{ kind: "read" } | { kind: "click"; target: string }> = [];
  private readonly screen: ScreenSnapshot;

  constructor(screen: ScreenSnapshot) {
    this.screen = screen;
  }

  readScreen(): ScreenSnapshot {
    this.calls.push({ kind: "read" });
    return this.screen;
  }

  focus(): void {
    throw new Error("unused");
  }

  click(target: string): void {
    this.calls.push({ kind: "click", target });
    throw new AdapterTimeoutError(`click timed out waiting for ${target}`);
  }

  type(): void {
    throw new Error("unused");
  }
}

function assertOsStepResults(
  rows: readonly StepResult[],
  driver: StepResult["driver"],
  expected: readonly {
    stepId: string;
    status: StepResult["status"];
    attempt: StepResult["attempt"];
    summary: string;
    target: StepResult["target"];
  }[],
): void {
  assert.equal(rows.length, expected.length);
  for (const [index, row] of expected.entries()) {
    const actual = rows[index];
    assert.equal(actual?.stepId, row.stepId);
    assert.equal(actual?.status, row.status);
    assert.equal(actual?.attempt, row.attempt);
    assert.equal(actual?.observation.summary, row.summary);
    assert.deepEqual(actual?.target, row.target);
    assert.equal(actual?.driver, driver);
    assert.equal(typeof actual?.timingMs, "number");
    assert.equal(actual!.timingMs >= 0, true);
    if (row.attempt === "not_executed") assert.equal(actual?.timingMs, 0);
  }
}
