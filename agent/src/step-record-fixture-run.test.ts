import assert from "node:assert/strict";
import { test } from "node:test";
import { createElement } from "react";
import { renderToStaticMarkup } from "react-dom/server";
import type { StepOutcome } from "../../packages/playbook-runtime/src/playbook";
import {
  dumpStepResults,
  parseStepResultsJson,
  type StepResultStatus,
} from "../../packages/playbook-runtime/src/step-result";
import {
  fixturePlaybook,
  fixtureTimeoutTarget,
  runFixture,
  runFixturePlaybook,
} from "./ui/step-record-fixture-run";
import { StepRecordPanel } from "./ui/step-record-panel";

/** How PlaybookRuntime maps its runner-log outcome onto the emitted status. */
function statusForOutcome(outcome: StepOutcome): StepResultStatus {
  switch (outcome) {
    case "ok": return "ok";
    case "timeout": return "retryable";
    case "failed": return "failed";
    case "permission_denied": return "protected";
    case "precondition_failed": return "failed";
    default: {
      const _never: never = outcome;
      return _never;
    }
  }
}

test("the fixture run emits one StepResult per declared step, in order", () => {
  const steps = runFixturePlaybook();
  assert.deepEqual(steps.map(step => step.stepId), fixturePlaybook.steps.map(step => step.id));
  assert.ok(steps.every(step => step.playbookId === fixturePlaybook.id && step.adapter === "os-windows"));
  assert.deepEqual(steps.map(step => step.status), ["ok", "ok", "retryable", "failed"]);
  assert.deepEqual(steps.map(step => step.attempt), ["executed", "executed", "timeout", "not_executed"]);
  assert.deepEqual(steps[2]?.target, { kind: "accessibility", name: fixtureTimeoutTarget });
  assert.deepEqual(steps[3]?.target, { kind: "none" });
});

test("emitted statuses match the runtime's own outcomes for every evaluated step", () => {
  const result = runFixture();
  assert.equal(result.status, "stopped");
  assert.equal(result.stopReason, "timeout");
  assert.equal(result.evidence.length, 3, "the runner log stops at the timed-out step");

  for (const entry of result.evidence) {
    const row = result.stepResults.find(step => step.stepId === entry.stepId);
    assert.ok(row, `no StepResult for ${entry.stepId}`);
    assert.equal(row.status, statusForOutcome(entry.outcome), entry.stepId);
    assert.equal(row.attempt, entry.outcome === "timeout" ? "timeout" : "executed", entry.stepId);
    assert.equal(row.observation.summary, entry.note);
  }
  const evaluated = new Set(result.evidence.map(entry => entry.stepId));
  for (const row of result.stepResults.filter(step => !evaluated.has(step.stepId))) {
    assert.equal(row.status, "failed");
    assert.equal(row.attempt, "not_executed");
    assert.equal(row.timingMs, 0);
  }
});

test("the fixture run is schema-clean and records no evidence it did not capture", () => {
  const steps = runFixturePlaybook();
  const json = dumpStepResults(steps);
  assert.deepEqual(parseStepResultsJson(json), steps);
  assert.ok(steps.every(step => !("evidence" in step)), "no screenshots were taken, so none are recorded");
  assert.doesNotMatch(json, /"x":|"bounds":|"nodeId":/);
  assert.equal(runFixture().stepResults.length, steps.length, "re-running the fixture is deterministic");
});

test("StepRecordPanel renders the runtime's rows end to end", () => {
  const steps = runFixturePlaybook();
  const html = renderToStaticMarkup(createElement(StepRecordPanel, { steps }));
  assert.equal((html.match(/data-step-id="/g) ?? []).length, steps.length);
  assert.match(html, /data-step-id="read-list"[^>]*aria-pressed="true"/, "no screenshot on record, so the first step");
  assert.match(html, /선택한 스텝에는 증빙 화면이 없습니다/);
  assert.match(html, /data-status="retryable"/);
  assert.match(html, /시간 초과/);
  assert.match(html, /미실행/);
  assert.match(html, /did not respond in time/);
});
