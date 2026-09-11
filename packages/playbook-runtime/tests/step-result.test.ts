import assert from "node:assert/strict";
import { test } from "node:test";
import {
  dumpStepResults,
  parseStepResult,
  parseStepResultsJson,
  StepResultError,
  type StepAttempt,
  type StepDriver,
  type StepResult,
  type StepResultStatus,
} from "../src/index.ts";

const pageOk: StepResult = {
  stepId: "open-next",
  playbookId: "fixture-page-happy",
  driver: "page",
  action: "click",
  status: "ok",
  attempt: "executed",
  target: { kind: "locator", locator: "#next" },
  observation: { summary: "clicked #next on Demo Page" },
  evidence: {
    screenshotBefore: "runs/fixture/open-next.before.png",
    screenshotAfter: "runs/fixture/open-next.after.png",
  },
  timingMs: 42,
};

const osTimeout: StepResult = {
  stepId: "wait-cert",
  playbookId: "fixture-hybrid",
  driver: "os-windows",
  action: "read",
  status: "retryable",
  attempt: "timeout",
  target: { kind: "accessibility", name: "인증서" },
  observation: { summary: "UIA read timed out waiting for 인증서" },
  timingMs: 8000,
};

const notExecuted: StepResult = {
  stepId: "sign",
  playbookId: "fixture-hybrid",
  driver: "os-windows",
  action: "click",
  status: "failed",
  attempt: "not_executed",
  target: { kind: "accessibility", name: "서명" },
  observation: { summary: "previous step stopped the run; adapter was not called" },
  timingMs: 0,
};

const run: readonly StepResult[] = [
  pageOk,
  osTimeout,
  notExecuted,
  {
    stepId: "open-form",
    playbookId: "fixture-page-happy",
    driver: "page",
    action: "goto",
    status: "ok",
    attempt: "executed",
    target: { kind: "url", url: "https://example.test/form" },
    observation: { summary: "opened form url" },
    timingMs: 15,
  },
  {
    stepId: "confirm",
    playbookId: "fixture-macos",
    driver: "os-macos",
    action: "focus",
    status: "needs_human",
    attempt: "executed",
    target: { kind: "none" },
    observation: { summary: "cert PIN field needs the owner" },
    evidence: { screenshotAfter: "runs/fixture/confirm.after.png" },
    timingMs: 120,
  },
  {
    stepId: "tap-next",
    playbookId: "fixture-phone",
    driver: "phone",
    action: "click",
    status: "ambiguous",
    attempt: "executed",
    target: { kind: "accessibility", name: "다음" },
    observation: { summary: "two 다음 buttons on screen" },
    timingMs: 30,
  },
  {
    stepId: "fill-name",
    playbookId: "fixture-page-happy",
    driver: "page",
    action: "fill",
    status: "protected",
    attempt: "not_executed",
    target: { kind: "locator", locator: "#name" },
    observation: { summary: "missing permission ui.control" },
    timingMs: 0,
  },
];

test("dumpStepResults writes a JSON array and parseStepResultsJson round-trips", () => {
  const json = dumpStepResults(run);
  const parsed = parseStepResultsJson(json);

  assert.equal(json.startsWith("["), true);
  assert.equal(parsed.length, run.length);
  assert.deepEqual(parsed, run);
  assert.match(json, /"driver": "page"/);
  assert.doesNotMatch(json, /"adapter"/);
  assert.match(json, /"screenshotBefore": "runs\/fixture\/open-next.before.png"/);
  assert.doesNotMatch(json, /"x":/);
  assert.doesNotMatch(json, /approv/i);
});

test("timeout is not the same record as not_executed", () => {
  const timedOut = parseStepResult(osTimeout);
  const skipped = parseStepResult(notExecuted);

  assert.equal(timedOut.attempt, "timeout");
  assert.equal(skipped.attempt, "not_executed");
  assert.notEqual(timedOut.attempt, skipped.attempt);
  assert.equal(timedOut.stepId, "wait-cert");
  assert.equal(skipped.stepId, "sign");
  assert.equal("evidence" in timedOut, false);
});

test("target rejects coordinates and session geometry", () => {
  const withPixels = {
    ...pageOk,
    target: { kind: "locator", locator: "#next", x: 120, y: 40, width: 16, height: 8 },
  };
  const withBox = {
    ...pageOk,
    target: { kind: "accessibility", name: "Next", box: [0, 0, 10, 10], nodeId: "session-9" },
  };

  assert.throws(
    () => parseStepResult(withPixels),
    error =>
      error instanceof StepResultError
      && /coordinates or session geometry/.test(error.message)
      && /x/.test(error.message),
  );
  assert.throws(
    () => parseStepResult(withBox),
    error =>
      error instanceof StepResultError
      && /box/.test(error.message)
      && /nodeId/.test(error.message),
  );
});

test("every driver, status, and attempt value is accepted", () => {
  const drivers: StepDriver[] = ["page", "os-windows", "os-macos", "os-android", "phone"];
  const statuses: StepResultStatus[] = [
    "ok",
    "retryable",
    "ambiguous",
    "protected",
    "needs_human",
    "failed",
  ];
  const attempts: StepAttempt[] = ["executed", "timeout", "not_executed"];

  for (const driver of drivers) {
    parseStepResult({ ...pageOk, driver });
  }
  for (const status of statuses) {
    parseStepResult({ ...osTimeout, status });
  }
  for (const attempt of attempts) {
    parseStepResult({ ...notExecuted, attempt });
  }
});

test("missing required fields, bad enums, and invalid JSON fail closed", () => {
  assert.throws(() => parseStepResult({ ...pageOk, stepId: "" }), StepResultError);
  assert.throws(() => parseStepResult({ ...pageOk, driver: "playwright" }), StepResultError);
  assert.throws(() => parseStepResult({ ...pageOk, status: "permission_denied" }), StepResultError);
  assert.throws(() => parseStepResult({ ...pageOk, attempt: "skipped" }), StepResultError);
  assert.throws(() => parseStepResult({ ...pageOk, timingMs: -1 }), StepResultError);
  assert.throws(() => parseStepResult({ ...pageOk, target: "#next" }), StepResultError);
  assert.throws(() => parseStepResultsJson("{"), StepResultError);
  assert.throws(() => parseStepResultsJson("{}"), StepResultError);
});

test("adapter is accepted as a deprecated input alias and normalized to driver; the mirror is never serialized", () => {
  const { driver: _driver, ...withoutDriver } = pageOk;
  const parsed = parseStepResult({ ...withoutDriver, adapter: "os-android" });
  assert.equal(parsed.driver, "os-android");
  assert.equal(parsed.adapter, "os-android");
  assert.deepEqual(Object.keys(parsed).includes("adapter"), false);
  assert.doesNotMatch(dumpStepResults([parsed]), /"adapter"/);
  assert.throws(() => parseStepResult({ ...withoutDriver }), StepResultError);
});
