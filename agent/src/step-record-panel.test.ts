import assert from "node:assert/strict";
import { test } from "node:test";
import { createElement } from "react";
import { renderToStaticMarkup } from "react-dom/server";
import type { StepResult } from "../../packages/ppomi-body/src/step-result";
import {
  isStepNavigationKey,
  nextStepIndex,
  selectedStep,
  StepRecordPanel,
  type StepRecordPanelProps,
} from "./ui/step-record-panel";
import { fixtureScreenshots, fixtureSteps } from "./ui/step-result-fixtures";

const render = (props: StepRecordPanelProps) => renderToStaticMarkup(createElement(StepRecordPanel, props));
const stepIds = (html: string) => [...html.matchAll(/data-step-id="([^"]+)"/g)].map(match => match[1]);

test("StepRecordPanel renders one card per step under the 스텝 기록 heading", () => {
  const html = render({ steps: fixtureSteps, screenshots: fixtureScreenshots });
  assert.match(html, /<h3[^>]*>스텝 기록<\/h3>/);
  assert.match(html, new RegExp(`${fixtureSteps.length} 스텝`));
  assert.deepEqual(stepIds(html), fixtureSteps.map(step => step.stepId));
  assert.match(html, /aria-labelledby=/);
  assert.match(html, /data-empty="false"/);
});

test("StepRecordPanel shows the empty state when there are no steps", () => {
  const html = render({ steps: [] });
  assert.match(html, /기록된 스텝이 없습니다/);
  assert.match(html, /data-empty="true"/);
  assert.deepEqual(stepIds(html), []);
  assert.doesNotMatch(html, /highlight-overlay/);
  assert.doesNotMatch(html, /스텝<\/span>/, "no count without steps");
});

test("StepRecordPanel selects the first step with a screenshot and resolves its picture", () => {
  const consulted: string[] = [];
  const html = render({
    steps: fixtureSteps,
    screenshots: step => { consulted.push(step.stepId); return fixtureScreenshots(step); },
  });
  const first = fixtureSteps.find(step => step.evidence)!;
  assert.equal(first.stepId, "open-next");
  assert.match(html, new RegExp(`data-step-id="${first.stepId}"[^>]*aria-pressed="true"`));
  assert.equal((html.match(/aria-pressed="true"/g) ?? []).length, 1);
  assert.deepEqual(consulted, ["open-next"], "the resolver is asked only for the selected step");
  assert.match(html, /<img[^>]*src="data:image\/svg\+xml/);
  assert.match(html, /open-next 스텝 증빙 · 실행 후/);
  assert.doesNotMatch(html, /runs\/fixture/);
  assert.doesNotMatch(html, /증빙 화면이 없습니다/);
});

test("StepRecordPanel honours defaultSelectedStepId and explains a step without a screenshot", () => {
  const html = render({ steps: fixtureSteps, screenshots: fixtureScreenshots, defaultSelectedStepId: "wait-cert" });
  assert.match(html, /data-step-id="wait-cert"[^>]*aria-pressed="true"/);
  assert.match(html, /선택한 스텝에는 증빙 화면이 없습니다/);
  assert.doesNotMatch(html, /<img/);
  assert.doesNotMatch(html, /highlight-overlay/);

  const unknown = render({ steps: fixtureSteps, screenshots: fixtureScreenshots, defaultSelectedStepId: "nope" });
  assert.match(unknown, /data-step-id="open-next"[^>]*aria-pressed="true"/, "unknown ids fall back");
});

test("selectedStep falls back in order: chosen, first with screenshot, first", () => {
  const steps: readonly StepResult[] = fixtureSteps;
  assert.equal(selectedStep(steps, "sign")?.stepId, "sign");
  assert.equal(selectedStep(steps, undefined)?.stepId, "open-next");
  assert.equal(selectedStep(steps, "missing")?.stepId, "open-next");
  const noShots = steps.filter(step => !step.evidence);
  assert.equal(selectedStep(noShots, undefined)?.stepId, noShots[0]?.stepId);
  assert.equal(selectedStep([], "sign"), undefined);
});

test("nextStepIndex moves with arrows, Home and End and wraps", () => {
  assert.equal(nextStepIndex(0, "ArrowDown", 3), 1);
  assert.equal(nextStepIndex(2, "ArrowDown", 3), 0);
  assert.equal(nextStepIndex(0, "ArrowUp", 3), 2);
  assert.equal(nextStepIndex(-1, "ArrowDown", 3), 0);
  assert.equal(nextStepIndex(-1, "ArrowUp", 3), 2);
  assert.equal(nextStepIndex(1, "Home", 3), 0);
  assert.equal(nextStepIndex(1, "End", 3), 2);
  assert.equal(nextStepIndex(0, "ArrowDown", 0), -1);
  assert.equal(isStepNavigationKey("ArrowDown"), true);
  assert.equal(isStepNavigationKey("Enter"), false);
});
