import assert from "node:assert/strict";
import { test } from "node:test";
import {
  AdapterTimeoutError,
  DummyAdapter,
  DummyPageAdapter,
  FixedPermissionGate,
  PagePlaybookRuntime,
  PlaybookRuntime,
  StepResultError,
  dumpStepResults,
  parseStepResult,
  parseStepResultsJson,
  type BrowserPageDriver,
  type OsUiDriver,
  type PageSnapshot,
  type ScreenSnapshot,
  type StepResult,
} from "../src/index.ts";

/*
 * Additive changes to the #17 schema, proposed back to that PR:
 * 1. `code?: string` for structured runtime / executor codes
 * 2. `observation.summary` bounded in the parser (2 KiB, truncated with a marker)
 * 3. `target` keys whitelisted (`kind`, `locator`, `url`, `name`, `role`); `url` is origin + pathname only
 * 4. (mapper, not schema) a timed-out click / fill / type is never `retryable`
 */

const screen: ScreenSnapshot = { title: "Demo App", texts: ["Demo App", "Next", "Name"], focused: null };
const page: PageSnapshot = { url: "https://shop.test/start", title: "Start", texts: ["Start", "Next"], locators: ["#next", "#name"] };
const all = new FixedPermissionGate(["ui.read", "ui.control"]);

const base: StepResult = {
  stepId: "open-next",
  playbookId: "fixture",
  driver: "page",
  action: "click",
  status: "ok",
  attempt: "executed",
  target: { kind: "locator", locator: "#next" },
  observation: { summary: "clicked" },
  timingMs: 1,
};

test("proposal 1: code travels as a structured field and survives the JSON round-trip", () => {
  const parsed = parseStepResult({ ...base, status: "protected", attempt: "executed", code: "protected_action" });
  assert.equal(parsed.code, "protected_action");
  assert.deepEqual(parseStepResultsJson(dumpStepResults([parsed])), [parsed]);
  assert.equal("code" in parseStepResult(base), false);
  assert.throws(() => parseStepResult({ ...base, code: "" }), StepResultError);
});

test("proposal 1: the runtime emits a code on every non-ok result and none on ok", () => {
  const denied = new PlaybookRuntime(new DummyAdapter(screen), new FixedPermissionGate(["ui.read"])).run({
    id: "codes",
    steps: [{ id: "n", kind: "click", target: "Next" }, { id: "later", kind: "read" }],
  });
  assert.deepEqual(denied.stepResults.map(row => row.code), ["permission_denied", "not_executed"]);

  const commit = new PlaybookRuntime(new DummyAdapter(screen), all).run({
    id: "codes-commit",
    steps: [{ id: "ok", kind: "read" }, { id: "pay", kind: "click", target: "Next", effect: "commit" }],
  });
  assert.deepEqual(commit.stepResults.map(row => row.code), [undefined, "commit"]);
  assert.deepEqual(commit.stepResults.map(row => row.driver), ["os-windows", "os-windows"]);

  const refusedNavigation = new PagePlaybookRuntime(new DummyPageAdapter(page), all).run({
    id: "codes-goto",
    allowedOrigins: ["https://shop.test"],
    steps: [{ id: "leave", kind: "goto", url: "https://evil.test/", effect: "navigate" }],
  });
  assert.equal(refusedNavigation.stepResults[0]?.code, "navigation_refused");

  const executorCode = new (class implements OsUiDriver {
    readonly kind = "os-windows" as const;
    readScreen(): ScreenSnapshot { return screen; }
    focus(): void { throw new Error("unused"); }
    click(): void { throw Object.assign(new Error("snapshot expired"), { code: "stale_screen" }); }
    type(): void { throw new Error("unused"); }
  })();
  const stale = new PlaybookRuntime(executorCode, all).run({ id: "codes-stale", steps: [{ id: "n", kind: "click", target: "Next", effect: "navigate" }] });
  assert.deepEqual([stale.stepResults[0]?.code, stale.stepResults[0]?.status], ["stale_screen", "retryable"]);
});

test("proposal 2: observation.summary is bounded to 2 KiB with a visible marker", () => {
  const long = "a".repeat(1024 * 1024);
  const parsed = parseStepResult({ ...base, observation: { summary: long } });
  assert.equal(parsed.observation.summary.length, 2048);
  assert.equal(parsed.observation.summary.endsWith(" …[truncated]"), true);
  assert.equal(parseStepResult({ ...base, observation: { summary: "x".repeat(2048) } }).observation.summary.length, 2048);
});

test("proposal 3: target keys are a whitelist; unknown geometry keys are errors, not silently dropped", () => {
  for (const target of [
    { kind: "locator", locator: "#next", left: 10, top: 20 },
    { kind: "locator", locator: "#next", rect: { x: 1, y: 2 } },
    { kind: "accessibility", name: "Next", cx: 300, cy: 900 },
    { kind: "accessibility", name: "Next", nodeId: "session-9" },
  ]) {
    assert.throws(() => parseStepResult({ ...base, target }), (error: unknown) =>
      error instanceof StepResultError && /coordinates or session geometry/.test(error.message));
  }
  assert.deepEqual(parseStepResult({ ...base, target: { kind: "accessibility", name: "다음", role: "button" } }).target, {
    kind: "accessibility",
    name: "다음",
    role: "button",
  });
});

test("proposal 3: target.url is origin + pathname only", () => {
  assert.deepEqual(parseStepResult({ ...base, action: "goto", target: { kind: "url", url: "https://shop.test/form" } }).target, {
    kind: "url",
    url: "https://shop.test/form",
  });
  for (const url of ["https://shop.test/form?session=SECRET", "https://shop.test/form#frag", "https://user:pw@shop.test/", "not a url", "javascript:alert(1)?x"]) {
    assert.throws(() => parseStepResult({ ...base, action: "goto", target: { kind: "url", url } }), StepResultError, url);
  }

  const adapter = new DummyPageAdapter(page);
  const result = new PagePlaybookRuntime(adapter, all).run({
    id: "url-target",
    allowedOrigins: ["https://shop.test"],
    steps: [{ id: "open", kind: "goto", url: "https://shop.test/form?lang=ko#top", effect: "navigate" }],
  });
  assert.deepEqual(result.stepResults[0]?.target, { kind: "url", url: "https://shop.test/form" });
  assert.deepEqual(adapter.calls.at(-1), { kind: "goto", url: "https://shop.test/form?lang=ko#top" });
});

test("proposal 4: a timed-out click / fill / type is needs_human, never retryable; reads and waits stay retryable", () => {
  class TimeoutEverything implements OsUiDriver {
    readonly kind = "os-windows" as const;
    readScreen(): ScreenSnapshot { return { ...screen, texts: [...screen.texts, "결제하기"] }; }
    focus(target: string): void { throw new AdapterTimeoutError(`focus timed out: ${target}`); }
    click(target: string): void { throw new AdapterTimeoutError(`click timed out: ${target}`); }
    type(target: string): void { throw new AdapterTimeoutError(`type timed out: ${target}`); }
  }
  const runtime = new PlaybookRuntime(new TimeoutEverything(), all);
  const click = runtime.run({ id: "t-click", steps: [{ id: "pay", kind: "click", target: "결제하기", effect: "navigate" }] });
  assert.deepEqual([click.stopReason, click.stepResults[0]?.status, click.stepResults[0]?.attempt, click.stepResults[0]?.code], ["timeout", "needs_human", "timeout", "timeout"]);
  const type = runtime.run({ id: "t-type", steps: [{ id: "name", kind: "type", target: "Name", text: "x", effect: "input" }] });
  assert.equal(type.stepResults[0]?.status, "needs_human");
  const focus = runtime.run({ id: "t-focus", steps: [{ id: "app", kind: "focus", target: "Demo App", effect: "navigate" }] });
  assert.equal(focus.stepResults[0]?.status, "retryable");

  class TimeoutPage implements BrowserPageDriver {
    readPage(): PageSnapshot { return page; }
    goto(): void { throw new Error("unused"); }
    click(): void { throw new Error("unused"); }
    fill(locator: string): void { throw new AdapterTimeoutError(`fill timed out: ${locator}`); }
    waitFor(locator: string): void { throw new AdapterTimeoutError(`waitFor timed out: ${locator}`); }
  }
  const pageRuntime = new PagePlaybookRuntime(new TimeoutPage(), all);
  const fill = pageRuntime.run({ id: "t-fill", steps: [{ id: "f", kind: "fill", locator: "#name", text: "x", effect: "input" }] });
  assert.equal(fill.stepResults[0]?.status, "needs_human");
  const wait = pageRuntime.run({ id: "t-wait", steps: [{ id: "w", kind: "waitFor", locator: "#cert" }] });
  assert.deepEqual([wait.stepResults[0]?.status, wait.stepResults[0]?.attempt], ["retryable", "timeout"]);
});
