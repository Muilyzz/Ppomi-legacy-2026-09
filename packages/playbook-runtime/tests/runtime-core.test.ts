import assert from "node:assert/strict";
import { test } from "node:test";
import {
  DummyAdapter,
  DummyPageAdapter,
  FixedPermissionGate,
  OsSurface,
  PagePlaybookRuntime,
  PageSurface,
  PlaybookRuntime,
  Runtime,
  dumpStepResults,
  navigationRefusal,
  parseStepResultsJson,
  publicUrl,
  requiredPermissions,
  type OsAdapter,
  type PageSnapshot,
  type RuntimeOptions,
  type ScreenSnapshot,
} from "../src/index.ts";

const screen: ScreenSnapshot = {
  title: "Demo App",
  texts: ["Demo App", "Next", "Name", "결제하기"],
  focused: null,
};

const page: PageSnapshot = {
  url: "https://shop.test/checkout?session=SECRET-TOKEN#step2",
  title: "Checkout",
  texts: ["Checkout", "총 결제금액 39,000원", "Name"],
  locators: ["#pay", "#name", "#pw"],
};

const all = new FixedPermissionGate(["ui.read", "ui.control"]);
const readOnly = new FixedPermissionGate(["ui.read"]);

class CodedFailureAdapter implements OsAdapter {
  readonly kind = "os-windows" as const;
  readonly calls: string[] = [];
  private readonly inner = new DummyAdapter(screen);
  private readonly failOn: "readScreen" | "click";
  private readonly code: string;

  constructor(failOn: "readScreen" | "click", code: string) {
    this.failOn = failOn;
    this.code = code;
  }

  readScreen(): ScreenSnapshot {
    this.calls.push("readScreen");
    if (this.failOn === "readScreen") throw Object.assign(new Error("lease lost"), { code: this.code });
    return this.inner.readScreen();
  }
  focus(target: string): void {
    this.calls.push("focus");
    this.inner.focus(target);
  }
  click(target: string): void {
    this.calls.push("click");
    if (this.failOn === "click") throw Object.assign(new Error("executor refused the node"), { code: this.code });
    this.inner.click(target);
  }
  type(target: string, text: string): void {
    this.calls.push("type");
    this.inner.type(target, text);
  }
}

/** A promise-returning adapter, as a real UIA/AX bridge or Playwright page would be. */
class AsyncDummyAdapter implements OsAdapter {
  readonly kind = "os-macos" as const;
  readonly inner = new DummyAdapter(screen, "os-macos");
  async readScreen(): Promise<ScreenSnapshot> {
    return this.inner.readScreen();
  }
  async focus(target: string): Promise<void> {
    this.inner.focus(target);
  }
  async click(target: string): Promise<void> {
    this.inner.click(target);
  }
  async type(target: string, text: string): Promise<void> {
    this.inner.type(target, text);
  }
}

function virtualClock(onSleep: (elapsed: number) => void): RuntimeOptions {
  let clock = 0;
  const advance = (ms: number): void => {
    clock += ms;
    onSleep(clock);
  };
  return {
    pollIntervalMs: 100,
    now: () => clock,
    sleep: async ms => advance(ms),
    sleepSync: ms => advance(ms),
  };
}

test("requiredPermissions always includes ui.read and the kind default; declared permissions only add", () => {
  assert.deepEqual(requiredPermissions({ id: "a", kind: "click" }, "ui.control"), ["ui.read", "ui.control"]);
  assert.deepEqual(requiredPermissions({ id: "b", kind: "click", require: { permission: "ui.read" } }, "ui.control"), ["ui.read", "ui.control"]);
  assert.deepEqual(requiredPermissions({ id: "c", kind: "read" }, "ui.read"), ["ui.read"]);
  assert.deepEqual(requiredPermissions({ id: "d", kind: "read", require: { permission: "ui.control" } }, "ui.read"), ["ui.read", "ui.control"]);
});

test("playbook data cannot downgrade a mutation to ui.read on either surface", () => {
  const os = new DummyAdapter(screen);
  const osResult = new PlaybookRuntime(os, readOnly).run({
    id: "downgrade-os",
    steps: [{ id: "n", kind: "click", target: "Next", effect: "navigate", require: { permission: "ui.read" } }],
  });
  assert.equal(osResult.stopReason, "permission_denied");
  assert.equal(osResult.evidence[0]?.note, "missing permission ui.control");
  assert.deepEqual(osResult.stepResults.map(row => [row.status, row.attempt]), [["protected", "not_executed"]]);
  assert.deepEqual(os.calls, []);

  const web = new DummyPageAdapter(page);
  for (const step of [
    { id: "g", kind: "goto" as const, url: "https://shop.test/next", effect: "navigate" as const, require: { permission: "ui.read" as const } },
    { id: "c", kind: "click" as const, locator: "#pay", effect: "navigate" as const, require: { permission: "ui.read" as const } },
    { id: "f", kind: "fill" as const, locator: "#pw", text: "hunter2", effect: "input" as const, require: { permission: "ui.read" as const } },
  ]) {
    const result = new PagePlaybookRuntime(web, readOnly).run({ id: "downgrade-page", steps: [step] });
    assert.equal(result.stopReason, "permission_denied", step.id);
  }
  assert.deepEqual(web.calls, []);
});

test("ui.control alone is refused: every step needs ui.read to observe the surface", () => {
  const adapter = new DummyAdapter(screen);
  const result = new PlaybookRuntime(adapter, new FixedPermissionGate(["ui.control"])).run({
    id: "control-only",
    steps: [{ id: "n", kind: "click", target: "Next", effect: "navigate" }],
  });
  assert.equal(result.stopReason, "permission_denied");
  assert.equal(result.evidence[0]?.note, "missing permission ui.read");
  assert.deepEqual(adapter.calls, []);
});

test("Runtime hands off a mutation without a declared effect before any adapter call", async () => {
  for (const step of [
    { id: "focus", kind: "focus" as const, target: "Demo App" },
    { id: "click", kind: "click" as const, target: "Next" },
    { id: "type", kind: "type" as const, target: "Name", text: "fixture" },
  ]) {
    const adapter = new DummyAdapter(screen);
    const result = await new Runtime(new OsSurface(adapter), all).run({
      id: "undeclared",
      steps: [step, { id: "later", kind: "click", target: "Next", effect: "navigate" }],
    });
    assert.equal(result.stopReason, "handoff", step.id);
    assert.deepEqual(result.evidence.map(row => [row.stepId, row.outcome]), [[step.id, "handoff"]]);
    assert.deepEqual(result.stepResults.map(row => [row.stepId, row.status, row.attempt]), [
      [step.id, "needs_human", "not_executed"],
      ["later", "failed", "not_executed"],
    ]);
    assert.deepEqual(adapter.calls, [{ kind: "read" }], step.id);
  }
});

test("the deprecated wrappers run undeclared mutations (legacy) but still hand off a declared commit", () => {
  const legacy = new DummyAdapter(screen);
  const legacyResult = new PlaybookRuntime(legacy, all).run({
    id: "legacy",
    steps: [{ id: "n", kind: "click", target: "Next" }],
  });
  assert.equal(legacyResult.status, "completed");
  assert.deepEqual(legacy.calls.at(-1), { kind: "click", target: "Next" });

  const adapter = new DummyAdapter(screen);
  const result = new PlaybookRuntime(adapter, all).run({
    id: "commit",
    steps: [
      { id: "open-next", kind: "click", target: "Next", effect: "navigate" },
      { id: "pay", kind: "click", target: "결제하기", effect: "commit" },
      { id: "after", kind: "read" },
    ],
  });
  assert.equal(result.stopReason, "handoff");
  assert.deepEqual(result.stepResults.map(row => [row.stepId, row.status, row.attempt]), [
    ["open-next", "ok", "executed"],
    ["pay", "needs_human", "not_executed"],
    ["after", "failed", "not_executed"],
  ]);
  assert.deepEqual(adapter.calls.filter(call => call.kind === "click"), [{ kind: "click", target: "Next" }]);

  const web = new DummyPageAdapter(page);
  const pageResult = new PagePlaybookRuntime(web, all).run({
    id: "commit-page",
    steps: [{ id: "pay", kind: "click", locator: "#pay", effect: "commit" }],
  });
  assert.equal(pageResult.stopReason, "handoff");
  assert.equal(pageResult.stepResults[0]?.status, "needs_human");
  assert.deepEqual(web.calls, [{ kind: "read" }]);
});

test("an adapter throw during act keeps earlier evidence and its executor code decides the status", () => {
  const refused = new CodedFailureAdapter("click", "protected_action");
  const result = new PlaybookRuntime(refused, all).run({
    id: "throwing",
    steps: [
      { id: "focus-app", kind: "focus", target: "Demo App", effect: "navigate" },
      { id: "open-next", kind: "click", target: "Next", effect: "navigate" },
      { id: "fill-name", kind: "type", target: "Name", text: "fixture", effect: "input" },
    ],
  });
  assert.equal(result.stopReason, "failed");
  assert.deepEqual(result.evidence.map(row => [row.stepId, row.outcome]), [["focus-app", "ok"], ["open-next", "failed"]]);
  assert.equal(result.evidence[1]?.note, "executor refused the node");
  assert.deepEqual(result.stepResults.map(row => [row.stepId, row.status, row.attempt]), [
    ["focus-app", "ok", "executed"],
    ["open-next", "protected", "executed"],
    ["fill-name", "failed", "not_executed"],
  ]);
  assert.deepEqual(refused.calls, ["readScreen", "focus", "readScreen", "click"]);

  const stale = new CodedFailureAdapter("click", "stale_screen");
  const staleResult = new PlaybookRuntime(stale, all).run({
    id: "stale",
    steps: [{ id: "open-next", kind: "click", target: "Next", effect: "navigate" }],
  });
  assert.deepEqual(staleResult.stepResults.map(row => [row.status, row.attempt]), [["retryable", "executed"]]);
});

test("an adapter throw during read is a failed step, not an escaping exception", () => {
  const adapter = new CodedFailureAdapter("readScreen", "stale_screen");
  const result = new PlaybookRuntime(adapter, all).run({
    id: "read-fails",
    steps: [{ id: "open-next", kind: "click", target: "Next", effect: "navigate" }],
  });
  assert.equal(result.stopReason, "failed");
  assert.equal(result.evidence[0]?.note, "lease lost");
  assert.deepEqual(result.stepResults.map(row => [row.status, row.attempt]), [["retryable", "executed"]]);
  assert.deepEqual(adapter.calls, ["readScreen"]);
});

test("require.wait polls the surface until the precondition holds, then acts (sync and async drivers)", async () => {
  const sync = new DummyAdapter({ ...screen, texts: ["Demo App"] });
  const syncResult = new PlaybookRuntime(sync, all, virtualClock(elapsed => {
    if (elapsed >= 300) sync.setScreen(screen);
  })).run({
    id: "wait-ok",
    steps: [{ id: "open-next", kind: "click", target: "Next", effect: "navigate", require: { wait: 1000 } }],
  });
  assert.equal(syncResult.status, "completed");
  assert.equal(sync.calls.filter(call => call.kind === "read").length, 4);
  assert.deepEqual(sync.calls.at(-1), { kind: "click", target: "Next" });

  const asyncAdapter = new AsyncDummyAdapter();
  asyncAdapter.inner.setScreen({ ...screen, texts: ["Demo App"] });
  const asyncResult = await new Runtime(new OsSurface(asyncAdapter), all, virtualClock(elapsed => {
    if (elapsed >= 300) asyncAdapter.inner.setScreen(screen);
  })).run({
    id: "wait-ok-async",
    steps: [{ id: "open-next", kind: "click", target: "Next", effect: "navigate", require: { wait: 1000 } }],
  });
  assert.equal(asyncResult.status, "completed");
  assert.equal(asyncResult.stepResults[0]?.adapter, "os-macos");
});

test("require.wait gives up at the deadline as a retryable timeout with no mutation", () => {
  const adapter = new DummyAdapter({ ...screen, texts: ["Demo App"] });
  const result = new PlaybookRuntime(adapter, all, virtualClock(() => undefined)).run({
    id: "wait-timeout",
    steps: [{ id: "open-next", kind: "click", target: "Next", effect: "navigate", require: { wait: 250 } }],
  });
  assert.equal(result.stopReason, "precondition_failed");
  assert.equal(result.evidence[0]?.note, "target not on screen: Next");
  assert.deepEqual(result.stepResults.map(row => [row.status, row.attempt, row.timingMs]), [["retryable", "timeout", 300]]);
  assert.equal(adapter.calls.filter(call => call.kind === "read").length, 4);
  assert.equal(adapter.calls.some(call => call.kind === "click"), false);
});

test("require.locators with wait replaces a page waitFor step", () => {
  const adapter = new DummyPageAdapter({ ...page, url: "https://shop.test/start", locators: [] });
  const result = new PagePlaybookRuntime(adapter, all, virtualClock(elapsed => {
    if (elapsed >= 200) adapter.setPage({ ...page, url: "https://shop.test/start" });
  })).run({
    id: "wait-locator",
    steps: [{ id: "ready", kind: "read", require: { locators: ["#name"], wait: 1000 } }],
  });
  assert.equal(result.status, "completed");
  assert.equal(adapter.calls.filter(call => call.kind === "read").length, 3);
});

test("results bound observed texts, keep urls to origin+pathname, never carry typed text, and round-trip", () => {
  const many = Array.from({ length: 500 }, (_, index) => `row ${index}`);
  const adapter = new DummyPageAdapter({ ...page, texts: [...page.texts, "x".repeat(1000), ...many] });
  const result = new PagePlaybookRuntime(adapter, all).run({
    id: "hygiene",
    steps: [
      { id: "fill-pw", kind: "fill", locator: "#pw", text: "hunter2", effect: "input" },
      { id: "confirm", kind: "read", require: { url: "https://shop.test/receipt" } },
    ],
  });
  const serialized = JSON.stringify(result);
  assert.doesNotMatch(serialized, /hunter2/);
  assert.doesNotMatch(serialized, /SECRET-TOKEN|session=|#step2/);
  assert.equal(result.evidence[0]?.screenTexts.length, 200);
  assert.equal(Math.max(...result.evidence[0]!.screenTexts.map(text => text.length)), 200);
  assert.equal(result.evidence[1]?.note, "url https://shop.test/checkout !== https://shop.test/receipt");
  assert.deepEqual(result.stepResults.map(row => [row.status, row.attempt]), [["ok", "executed"], ["failed", "not_executed"]]);
  assert.deepEqual(parseStepResultsJson(dumpStepResults(result.stepResults)), result.stepResults);
  assert.equal(publicUrl("about:blank"), "about:blank");
  assert.equal(publicUrl("not a url"), "(invalid url)");
});

test("goto refuses non-HTTP(S), credentialed, relative and undeclared-origin urls as protected, without calling the adapter", () => {
  assert.equal(navigationRefusal("javascript:alert(1)"), "goto scheme javascript: is refused");
  assert.equal(navigationRefusal("file:///etc/passwd"), "goto scheme file: is refused");
  assert.equal(navigationRefusal("https://user:pw@evil.test/"), "goto url carries credentials");
  assert.equal(navigationRefusal("/relative"), "goto url is not absolute");
  assert.equal(navigationRefusal("https://evil.test/", ["https://shop.test"]), "goto origin https://evil.test is not declared");
  assert.equal(navigationRefusal("https://shop.test/next", ["https://shop.test"]), null);
  assert.equal(navigationRefusal("http://localhost:3000/"), null);

  const adapter = new DummyPageAdapter(page);
  const result = new PagePlaybookRuntime(adapter, all).run({
    id: "goto-refused",
    allowedOrigins: ["https://shop.test"],
    steps: [{ id: "leave", kind: "goto", url: "https://evil.test/", effect: "navigate" }],
  });
  assert.equal(result.stopReason, "precondition_failed");
  assert.deepEqual(result.stepResults.map(row => [row.status, row.attempt]), [["protected", "not_executed"]]);
  assert.equal(adapter.calls.some(call => call.kind === "goto"), false);
});

test("a redirect off the declared origins fails the next step as protected", () => {
  const adapter = new DummyPageAdapter({ ...page, url: "https://shop.test/start" });
  const original = adapter.goto.bind(adapter);
  adapter.goto = (url: string) => {
    original(url);
    adapter.setPage({ ...page, url: "https://phish.test/login" });
  };
  const result = new PagePlaybookRuntime(adapter, all).run({
    id: "redirect",
    allowedOrigins: ["https://shop.test"],
    steps: [
      { id: "open", kind: "goto", url: "https://shop.test/checkout", effect: "navigate" },
      { id: "fill", kind: "fill", locator: "#name", text: "fixture", effect: "input" },
    ],
  });
  assert.deepEqual(result.stepResults.map(row => [row.stepId, row.status, row.attempt]), [
    ["open", "ok", "executed"],
    ["fill", "protected", "not_executed"],
  ]);
  assert.equal(result.evidence[1]?.note, "page origin https://phish.test is not declared");
  assert.equal(adapter.calls.some(call => call.kind === "fill"), false);
});

test("runSync refuses a promise-returning adapter; run drives it", async () => {
  const adapter = new AsyncDummyAdapter();
  const runtime = new Runtime(new OsSurface(adapter), all);
  const playbook = { id: "async", steps: [{ id: "n", kind: "click" as const, target: "Next", effect: "navigate" as const }] };
  assert.throws(() => runtime.runSync(playbook), /returned a Promise from read; use Runtime.run/);
  const result = await runtime.run(playbook);
  assert.equal(result.status, "completed");
  assert.deepEqual(adapter.inner.calls.at(-1), { kind: "click", target: "Next" });
});

test("Runtime with a PageSurface reports adapter page and one StepResult per declared step", async () => {
  const web = new DummyPageAdapter(page);
  const result = await new Runtime(new PageSurface(web, ["https://shop.test"]), all).run({
    id: "direct-page",
    steps: [
      { id: "r", kind: "read", require: { texts: ["Checkout"] } },
      { id: "pay", kind: "click", locator: "#pay" },
      { id: "never", kind: "read" },
    ],
  });
  assert.equal(result.stopReason, "handoff");
  assert.deepEqual(result.stepResults.map(row => [row.adapter, row.stepId, row.status, row.attempt]), [
    ["page", "r", "ok", "executed"],
    ["page", "pay", "needs_human", "not_executed"],
    ["page", "never", "failed", "not_executed"],
  ]);
  assert.deepEqual(result.stepResults[1]?.target, { kind: "locator", locator: "#pay" });
});
