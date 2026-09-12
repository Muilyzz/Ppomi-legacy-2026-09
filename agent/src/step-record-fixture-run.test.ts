import assert from "node:assert/strict";
import { test } from "node:test";
import { createElement } from "react";
import { renderToStaticMarkup } from "react-dom/server";
import type { StepOutcome } from "../../packages/ppomi-body/src/playbook";
import {
  dumpStepResults,
  parseStepResultsJson,
  type StepResultStatus,
} from "../../packages/ppomi-body/src/step-result";
import {
  fixturePagePlaybook,
  fixturePlaybook,
  fixtureTimeoutTarget,
  runFixture,
  runFixturePlaybook,
} from "./ui/step-record-fixture-run";
import { StepRecordPanel } from "./ui/step-record-panel";

/** Which `StepResult.status` values the core may emit for a runner-log outcome (timeouts depend on the action). */
function statusesForOutcome(outcome: StepOutcome): readonly StepResultStatus[] {
  switch (outcome) {
    case "ok": return ["ok"];
    case "handoff": return ["needs_human"];
    case "timeout": return ["retryable", "needs_human"];
    case "permission_denied": return ["failed"];
    case "precondition_failed": return ["failed", "retryable"];
    case "failed": return ["failed", "retryable", "protected"];
    default: {
      const _never: never = outcome;
      return _never;
    }
  }
}

test("the OS fixture emits one row per declared step; a timed-out click goes to the person, never a retry", async () => {
  const result = await runFixture("os");
  const steps = await runFixturePlaybook("os");
  assert.deepEqual(steps, result.stepResults);
  assert.deepEqual(steps.map(step => step.stepId), fixturePlaybook.steps.map(step => step.id));
  assert.ok(steps.every(step => step.playbookId === fixturePlaybook.id && step.driver === "os-windows"));
  assert.deepEqual(steps.map(step => step.status), ["ok", "ok", "needs_human", "failed"]);
  assert.deepEqual(steps.map(step => step.attempt), ["executed", "executed", "timeout", "not_executed"]);
  assert.deepEqual(steps.map(step => step.code), [undefined, undefined, "timeout", "not_executed"]);
  assert.deepEqual(steps[2]?.target, { kind: "accessibility", name: fixtureTimeoutTarget });
  assert.deepEqual(steps[3]?.target, { kind: "none" });
  assert.equal(result.status, "stopped");
  assert.equal(result.stopReason, "timeout");
  assert.ok(fixturePlaybook.steps.filter(step => step.kind !== "read").every(step => step.effect !== undefined), "every mutation declares its effect");
});

test("the page fixture reaches the commit step and the core hands it off instead of paying", async () => {
  const result = await runFixture("page");
  const steps = result.stepResults;
  assert.deepEqual(steps.map(step => step.stepId), fixturePagePlaybook.steps.map(step => step.id));
  assert.ok(steps.every(step => step.driver === "page" && step.playbookId === fixturePagePlaybook.id));
  assert.deepEqual(steps.map(step => step.status), ["ok", "ok", "ok", "ok", "needs_human", "failed"]);
  assert.deepEqual(steps.map(step => step.attempt), ["executed", "executed", "executed", "executed", "not_executed", "not_executed"]);
  assert.deepEqual(steps.map(step => step.code), [undefined, undefined, undefined, undefined, "commit", "not_executed"]);
  assert.deepEqual(steps[0]?.target, { kind: "url", url: "https://example.test/form" });
  assert.deepEqual(steps[1]?.target, { kind: "locator", locator: "#name" });
  assert.deepEqual(steps[4]?.target, { kind: "locator", locator: "#pay" });
  assert.equal(result.status, "stopped");
  assert.equal(result.stopReason, "handoff");
  assert.match(steps[4]?.observation.summary ?? "", /the person takes this step/);
  assert.ok(fixturePagePlaybook.steps.filter(step => step.kind !== "read").every(step => step.effect !== undefined), "every mutation declares its effect");
  assert.equal(fixturePagePlaybook.steps.find(step => step.id === "pay")?.effect, "commit");
});

test("emitted statuses match the runner log on both surfaces; unreached steps are not_executed", async () => {
  for (const surface of ["os", "page"] as const) {
    const result = await runFixture(surface);
    assert.ok(result.evidence.length > 0 && result.evidence.length < result.stepResults.length, surface);
    for (const entry of result.evidence) {
      const row = result.stepResults.find(step => step.stepId === entry.stepId);
      assert.ok(row, `${surface}: no StepResult for ${entry.stepId}`);
      assert.ok(statusesForOutcome(entry.outcome).includes(row.status), `${surface}: ${entry.stepId} ${entry.outcome} → ${row.status}`);
      assert.equal(row.observation.summary, entry.note, entry.stepId);
    }
    const evaluated = new Set(result.evidence.map(entry => entry.stepId));
    for (const row of result.stepResults.filter(step => !evaluated.has(step.stepId))) {
      assert.equal(row.status, "failed", surface);
      assert.equal(row.attempt, "not_executed", surface);
      assert.equal(row.code, "not_executed", surface);
      assert.equal(row.timingMs, 0, surface);
    }
  }
});

test("both runs are schema-clean, deterministic, and record no evidence they did not capture", async () => {
  for (const surface of ["os", "page"] as const) {
    const steps = await runFixturePlaybook(surface);
    const json = dumpStepResults(steps);
    assert.deepEqual(parseStepResultsJson(json), steps, surface);
    assert.ok(steps.every(step => !("evidence" in step)), `${surface}: no screenshots were taken, so none are recorded`);
    assert.doesNotMatch(json, /"adapter":|"x":|"bounds":|"nodeId":/);
    assert.doesNotMatch(json, /\?/, "no query strings in the dump");
    if (surface === "page") assert.doesNotMatch(json, /홍길동/, "typed text never reaches the record");
    assert.ok(steps.some(step => step.timingMs > 0), "executed steps carry a timing from the virtual clock");
    assert.deepEqual(await runFixturePlaybook(surface), steps, `${surface}: re-running the fixture is deterministic`);
  }
});

test("StepRecordPanel renders both runs end to end and keeps its empty state", async () => {
  const os = renderToStaticMarkup(createElement(StepRecordPanel, { steps: await runFixturePlaybook("os") }));
  assert.equal((os.match(/data-step-id="/g) ?? []).length, fixturePlaybook.steps.length);
  assert.match(os, /data-step-id="read-list"[^>]*aria-pressed="true"/, "no screenshot on record, so the first step");
  assert.match(os, /선택한 스텝에는 증빙 화면이 없습니다/);
  assert.match(os, /사람 차례/);
  assert.match(os, /Windows · 시간 초과 · 확인 · <code class="step-card-code">timeout<\/code>/);
  assert.match(os, /did not respond in time/);

  const page = renderToStaticMarkup(createElement(StepRecordPanel, { steps: await runFixturePlaybook("page") }));
  assert.equal((page.match(/data-step-id="/g) ?? []).length, fixturePagePlaybook.steps.length);
  assert.match(page, /https:\/\/example.test\/form/);
  assert.match(page, /data-status="needs_human" data-step-id="pay"/);
  assert.match(page, /웹 페이지 · 미실행 · #pay · <code class="step-card-code">commit<\/code>/);
  assert.doesNotMatch(page, /홍길동/, "typed text never reaches the record");

  assert.match(renderToStaticMarkup(createElement(StepRecordPanel, { steps: [] })), /기록된 스텝이 없습니다/);
});
