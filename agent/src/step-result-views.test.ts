import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { test } from "node:test";
import { createElement, type ReactElement, type ReactNode } from "react";
import { renderToStaticMarkup } from "react-dom/server";
import { parseStepResultsJson } from "../../packages/playbook-runtime/src/step-result";
import {
  containedImageRect,
  evidencePhase,
  evidenceScreenshot,
  FULL_FRAME,
  HighlightOverlay,
  isStaticImageSrc,
  phaseLabel,
  placeBox,
  visibleOverlayBoxes,
} from "./ui/highlight-overlay";
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
  assert.doesNotMatch(html, /runs\/fixture/, "evidence paths never reach the DOM");
  assert.match(html, /스텝 증빙 · 실행 후/);
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
  assert.match(html, /data-measured="false"/, "boxes wait for the picture rect when an image is shown");
  assert.equal(isStaticImageSrc(overlay.imageSrc), true);
  assert.equal(isStaticImageSrc("runs/fixture/open-next.after.png"), false);
});

test("HighlightOverlay never renders or requests a machine path from evidence", () => {
  const home = "/Users/kim/Library/Application Support/ppomi/runs/7/after.png";
  const html = renderToStaticMarkup(createElement(HighlightOverlay, {
    evidence: { screenshotBefore: "C:\\Users\\kim\\ppomi\\before.png", screenshotAfter: home },
  }));
  assert.match(html, /data-empty="false"/);
  assert.doesNotMatch(html, /<img/, "a leading slash is a file path, not a URL");
  assert.doesNotMatch(html, /Users/);
  assert.doesNotMatch(html, /\.png/);
  assert.match(html, /실행 후/);

  const before = renderToStaticMarkup(createElement(HighlightOverlay, {
    evidence: { screenshotBefore: "runs/fixture/open-next.before.png" },
    alt: "인증서 화면",
  }));
  assert.match(before, /인증서 화면 · 실행 전/);
  assert.doesNotMatch(before, /runs\//);

  assert.equal(isStaticImageSrc(home), false);
  assert.equal(isStaticImageSrc("C:\\Users\\kim\\x.png"), false);
  assert.equal(isStaticImageSrc("blob:http://127.0.0.1:5173/3f0a"), true);
  assert.equal(isStaticImageSrc("https://example.test/shot.png"), true);
  assert.equal(evidencePhase({}), undefined);
  assert.equal(evidencePhase({ screenshotBefore: "a", screenshotAfter: "b" }), "after");
  assert.equal(phaseLabel("before"), "실행 전");
});

test("containedImageRect letterboxes like object-fit: contain and placeBox keeps boxes on the picture", () => {
  assert.deepEqual(containedImageRect(160, 100, 16, 10), FULL_FRAME);
  assert.deepEqual(containedImageRect(0, 100, 16, 10), FULL_FRAME);
  assert.deepEqual(containedImageRect(160, 100, 0, 0), FULL_FRAME);

  // Fixture SVG (400x260) in the 16:10 frame: full height, side bars.
  const svg = containedImageRect(542, 338, 400, 260);
  assert.equal(svg.height, 1);
  assert.ok(Math.abs(svg.width - (400 / 260) / (542 / 338)) < 1e-9);
  assert.ok(Math.abs(svg.left - (1 - svg.width) / 2) < 1e-9);

  // Phone screenshot (1170x2532) in the same frame: a 70% box must land inside the picture, not on the bars.
  const phone = containedImageRect(542, 338, 1170, 2532);
  const placed = placeBox({ id: "next", x: 0.7, y: 0.78, width: 0.22, height: 0.1 }, phone);
  assert.ok(phone.width < 0.3 && phone.left > 0.35);
  assert.ok(placed.left >= phone.left && placed.left + placed.width <= phone.left + phone.width + 1e-9);
  assert.ok(placed.top >= phone.top && placed.top + placed.height <= phone.top + phone.height + 1e-9);
  assert.ok(placed.left < 0.7, "frame-relative percent would have been 70%");
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
