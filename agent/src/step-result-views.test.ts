import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { test } from "node:test";
import { createElement, type ReactElement, type ReactNode } from "react";
import { renderToStaticMarkup } from "react-dom/server";
import { parseStepResultsJson } from "../../packages/playbook-runtime/src/step-result";
import {
  evidenceScreenshot,
  HighlightOverlay,
  isStaticImageSrc,
  visibleOverlayBoxes,
} from "./ui/highlight-overlay";
import { StepRecordPane } from "./ui/step-record-pane";
import { runFixtureStepRecord } from "./ui/step-record-run";
import { fixtureSteps, overlayFixture } from "./ui/step-result-fixtures";
import {
  adapterLabel,
  attemptLabel,
  statusLabel,
  StepTimeline,
  targetLabel,
} from "./ui/step-timeline";

const fixtureJson = readFileSync(new URL("./ui/fixtures/step-results.json", import.meta.url), "utf8");

function walk(node: ReactNode, visit: (el: ReactElement) => void) {
  if (node == null || typeof node === "boolean") return;
  if (Array.isArray(node)) {
    for (const child of node) walk(child, visit);
    return;
  }
  if (typeof node !== "object" || !("props" in node)) return;
  const el = node as ReactElement<{ children?: ReactNode }>;
  visit(el);
  walk(el.props.children, visit);
}

test("fixture JSON is a StepResult run covering every status", () => {
  const parsed = parseStepResultsJson(fixtureJson);
  assert.deepEqual(parsed, fixtureSteps);
  assert.deepEqual(new Set(parsed.map(step => step.status)), new Set([
    "ok", "retryable", "ambiguous", "protected", "needs_human", "failed",
  ]));
  assert.equal(parsed.some(step => step.evidence?.screenshotAfter), true);
  assert.equal(parsed.some(step => !("evidence" in step)), true);
  assert.doesNotMatch(fixtureJson, /"x":/);
  assert.doesNotMatch(fixtureJson, /"bounds":/);
});

test("HighlightOverlay hides when evidence has no screenshot", () => {
  const empty = renderToStaticMarkup(createElement(HighlightOverlay, {}));
  const noShot = renderToStaticMarkup(createElement(HighlightOverlay, { evidence: {} }));
  assert.match(empty, /data-empty="true"/);
  assert.match(empty, /hidden/);
  assert.match(noShot, /data-empty="true"/);
  assert.equal(evidenceScreenshot(undefined), undefined);
  assert.equal(evidenceScreenshot({}), undefined);
});

test("HighlightOverlay draws a placeholder and session boxes for file-path evidence", () => {
  const step = fixtureSteps.find(row => row.stepId === "open-next");
  assert.ok(step?.evidence);
  const overlay = overlayFixture("open-next");
  const html = renderToStaticMarkup(createElement(HighlightOverlay, {
    evidence: step.evidence,
    boxes: overlay?.boxes,
    selectedBoxId: overlay?.selectedBoxId,
  }));

  assert.match(html, /data-empty="false"/);
  assert.match(html, /highlight-overlay-placeholder/);
  assert.match(html, /runs\/fixture\/open-next.after.png/);
  assert.match(html, /data-box-id="next"/);
  assert.match(html, /data-selected="true"/);
  assert.match(html, /left:70%/);
  assert.match(html, /width:22%/);
  assert.match(html, /#next/);
  assert.doesNotMatch(html, /<img/);
});

test("HighlightOverlay uses a static image src when one is provided", () => {
  const step = fixtureSteps.find(row => row.stepId === "open-next");
  const overlay = overlayFixture("open-next");
  assert.ok(step?.evidence && overlay?.imageSrc);
  const html = renderToStaticMarkup(createElement(HighlightOverlay, {
    evidence: step.evidence,
    boxes: overlay.boxes,
    imageSrc: overlay.imageSrc,
  }));
  assert.match(html, /<img/);
  assert.match(html, /data:image\/svg\+xml/);
  assert.equal(isStaticImageSrc(overlay.imageSrc), true);
  assert.equal(isStaticImageSrc("runs/fixture/open-next.after.png"), false);
});

test("visibleOverlayBoxes drops invalid session geometry", () => {
  assert.deepEqual(visibleOverlayBoxes([
    { id: "ok", x: 0.1, y: 0.2, width: 0.3, height: 0.4 },
    { id: "", x: 0, y: 0, width: 1, height: 1 },
    { id: "zero", x: 0, y: 0, width: 0, height: 1 },
    { id: "nan", x: Number.NaN, y: 0, width: 1, height: 1 },
  ]), [{ id: "ok", x: 0.1, y: 0.2, width: 0.3, height: 0.4 }]);
});

test("StepTimeline renders status colors and calls onSelect", () => {
  const selected: string[] = [];
  const tree = StepTimeline({
    steps: fixtureSteps,
    selectedStepId: "wait-cert",
    onSelect: stepId => selected.push(stepId),
  });
  const html = renderToStaticMarkup(tree);

  for (const status of ["ok", "retryable", "ambiguous", "protected", "needs_human", "failed"] as const) {
    assert.match(html, new RegExp(`data-status="${status}"`));
    assert.match(html, new RegExp(statusLabel(status)));
  }
  assert.match(html, /data-step-id="wait-cert"[^>]*aria-pressed="true"/);
  assert.match(html, /시간 초과/);
  assert.match(html, /미실행/);
  assert.match(html, /#next/);
  assert.equal(adapterLabel("os-macos"), "os-macos");
  assert.equal(attemptLabel("timeout"), "시간 초과");
  assert.equal(targetLabel({ kind: "none" }), "—");

  const clicks: Array<() => void> = [];
  walk(tree, el => {
    if (el.type === "button" && typeof (el.props as { onClick?: unknown }).onClick === "function") {
      clicks.push((el.props as { onClick: () => void }).onClick);
    }
  });
  assert.equal(clicks.length, fixtureSteps.length);
  clicks[2]();
  assert.deepEqual(selected, ["sign"]);
});

test("fixture runtime run emits stepResults and attaches overlay evidence", () => {
  const steps = runFixtureStepRecord();
  const byId = Object.fromEntries(steps.map(step => [step.stepId, step]));

  assert.equal(byId["open-form"]?.adapter, "page");
  assert.equal(byId["open-form"]?.status, "ok");
  assert.equal(byId["open-next"]?.action, "click");
  assert.equal(byId["open-next"]?.evidence?.screenshotAfter, "runs/fixture/open-next.after.png");
  assert.equal(byId["wait-cert"]?.status, "retryable");
  assert.equal(byId["wait-cert"]?.attempt, "timeout");
  assert.equal("evidence" in (byId["wait-cert"] ?? {}), false);
  assert.equal(byId["sign"]?.attempt, "not_executed");
  assert.equal(byId["type-name"]?.status, "protected");
  assert.equal(byId["confirm"]?.adapter, "os-macos");
  assert.ok(byId["confirm"]?.evidence?.screenshotAfter);
  assert.equal(byId["tap-next"]?.adapter, "phone");
});

test("StepRecordPane select shows overlay only when evidence exists", () => {
  const steps = runFixtureStepRecord();
  const shown = renderToStaticMarkup(createElement(StepRecordPane, {
    steps,
    selectedStepId: "open-next",
    onSelect: () => {},
  }));
  const hidden = renderToStaticMarkup(createElement(StepRecordPane, {
    steps,
    selectedStepId: "wait-cert",
    onSelect: () => {},
  }));

  assert.match(shown, /data-empty="false"/);
  assert.match(shown, /data-box-id="next"/);
  assert.match(shown, /data-step-id="open-next"[^>]*aria-pressed="true"/);
  assert.match(shown, /스텝 기록/);
  assert.match(shown, /path \/ body/);
  assert.match(hidden, /data-empty="true"/);
  assert.match(hidden, /hidden/);
  assert.doesNotMatch(hidden, /data-box-id="next"/);
  assert.match(hidden, /data-step-id="wait-cert"[^>]*aria-pressed="true"/);
});
