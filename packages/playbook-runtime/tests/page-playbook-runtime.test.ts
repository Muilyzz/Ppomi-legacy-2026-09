import assert from "node:assert/strict";
import { test } from "node:test";
import {
  AdapterTimeoutError,
  DummyPageAdapter,
  FixedPermissionGate,
  PagePlaybookRuntime,
  defaultPagePermission,
  dumpStepResults,
  parseStepResultsJson,
  type BrowserPageAdapter,
  type PagePlaybook,
  type PageSnapshot,
  type PageStepKind,
  type StepResult,
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
  assert.deepEqual(result.stepResults.map(row => row.status), ["ok", "ok", "ok", "ok", "ok"]);
  assert.deepEqual(result.stepResults.map(row => row.attempt), [
    "executed",
    "executed",
    "executed",
    "executed",
    "executed",
  ]);
  assert.deepEqual(result.stepResults.map(row => row.action), [
    "goto",
    "waitFor",
    "click",
    "fill",
    "read",
  ]);
  assert.deepEqual(result.stepResults[0]?.target, {
    kind: "url",
    url: "https://example.test/form",
  });
  assert.deepEqual(result.stepResults[2]?.target, { kind: "locator", locator: "#next" });
  assert.equal(result.stepResults[0]?.adapter, "page");
  assert.equal(result.stepResults[0]?.playbookId, "fixture-page-happy");
  assert.deepEqual(parseStepResultsJson(dumpStepResults(result.stepResults)), result.stepResults);
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
  assertStepResults(result.stepResults, [
    {
      stepId: "open-next",
      status: "protected",
      attempt: "not_executed",
      summary: "missing permission ui.control",
      target: { kind: "locator", locator: "#next" },
    },
    {
      stepId: "fill-name",
      status: "failed",
      attempt: "not_executed",
      summary: "previous step stopped the run; adapter was not called",
      target: { kind: "locator", locator: "#name" },
    },
  ]);
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
  assert.equal(result.stepResults[0]?.attempt, "not_executed");
  assert.equal(result.stepResults[0]?.status, "failed");
  assert.equal(result.stepResults[1]?.attempt, "not_executed");
  assert.equal(result.stepResults[1]?.observation.summary, "previous step stopped the run; adapter was not called");
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
  assert.equal(result.stepResults[0]?.attempt, "not_executed");
  assert.equal(result.stepResults[1]?.attempt, "not_executed");
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
  assert.equal(result.stepResults.length, 1);
  assert.equal(result.stepResults[0]?.attempt, "executed");
});

test("waitFor timeout is attempt timeout, not not_executed", () => {
  const adapter = new TimeoutWaitPageAdapter(page);
  const runtime = new PagePlaybookRuntime(
    adapter,
    new FixedPermissionGate(["ui.read", "ui.control"]),
  );
  const result = runtime.run({
    id: "fixture-page-timeout",
    steps: [
      { id: "wait-cert", kind: "waitFor", locator: "#cert" },
      { id: "sign", kind: "click", locator: "#next" },
    ],
  });

  assert.equal(result.status, "stopped");
  assert.equal(result.stopReason, "timeout");
  assert.equal(result.evidence[0]?.outcome, "timeout");
  assert.deepEqual(adapter.calls, [{ kind: "read" }, { kind: "waitFor", locator: "#cert" }]);
  assertStepResults(result.stepResults, [
    {
      stepId: "wait-cert",
      status: "retryable",
      attempt: "timeout",
      summary: "waitFor timed out: #cert",
      target: { kind: "locator", locator: "#cert" },
    },
    {
      stepId: "sign",
      status: "failed",
      attempt: "not_executed",
      summary: "previous step stopped the run; adapter was not called",
      target: { kind: "locator", locator: "#next" },
    },
  ]);
  assert.notEqual(result.stepResults[0]?.attempt, result.stepResults[1]?.attempt);
});

test("error named TimeoutError is a timeout without importing Playwright", () => {
  const adapter = new NamedTimeoutPageAdapter(page);
  const runtime = new PagePlaybookRuntime(
    adapter,
    new FixedPermissionGate(["ui.read", "ui.control"]),
  );
  const result = runtime.run({
    id: "fixture-page-timeout-name",
    steps: [{ id: "wait-next", kind: "waitFor", locator: "#next" }],
  });

  assert.equal(result.stopReason, "timeout");
  assert.equal(result.stepResults[0]?.attempt, "timeout");
  assert.equal(result.stepResults[0]?.status, "retryable");
});

class TimeoutWaitPageAdapter implements BrowserPageAdapter {
  readonly calls: Array<{ kind: "read" } | { kind: "waitFor"; locator: string }> = [];
  private readonly page: PageSnapshot;

  constructor(page: PageSnapshot) {
    this.page = page;
  }

  readPage(): PageSnapshot {
    this.calls.push({ kind: "read" });
    return this.page;
  }

  goto(): void {
    throw new Error("unused");
  }

  click(): void {
    throw new Error("unused");
  }

  fill(): void {
    throw new Error("unused");
  }

  waitFor(locator: string): void {
    this.calls.push({ kind: "waitFor", locator });
    throw new AdapterTimeoutError(`waitFor timed out: ${locator}`);
  }
}

class NamedTimeoutPageAdapter implements BrowserPageAdapter {
  private readonly page: PageSnapshot;

  constructor(page: PageSnapshot) {
    this.page = page;
  }

  readPage(): PageSnapshot {
    return this.page;
  }

  goto(): void {
    throw new Error("unused");
  }

  click(): void {
    throw new Error("unused");
  }

  fill(): void {
    throw new Error("unused");
  }

  waitFor(locator: string): void {
    const error = new Error(`waitFor timed out: ${locator}`);
    error.name = "TimeoutError";
    throw error;
  }
}

function assertStepResults(
  rows: readonly StepResult[],
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
    assert.equal(actual?.adapter, "page");
    assert.equal(typeof actual?.timingMs, "number");
    assert.equal(actual!.timingMs >= 0, true);
    if (row.attempt === "not_executed") assert.equal(actual?.timingMs, 0);
  }
}
