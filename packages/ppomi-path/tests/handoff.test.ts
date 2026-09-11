import assert from "node:assert/strict";
import { test } from "node:test";
import {
  grantsUsed,
  handoffSteps,
  isHandoffStep,
  loadPath,
  pageStepsUntilHandoff,
  type PathDocument,
  type PathStep,
} from "../src/index.ts";

function documentOf(steps: readonly PathStep[]): PathDocument {
  return {
    schemaVersion: 1,
    id: "prefix-fixture",
    version: "0.1.0",
    title: "prefix fixture",
    surface: "os-windows",
    allowedOrigins: ["https://example.test"],
    steps,
  };
}

test("kb-star-biz-win-cert page prefix is gotos only; the rest is human handoff", () => {
  const document = loadPath("kb-star-biz-win-cert", { version: "0.1.0" });
  assert.deepEqual(
    pageStepsUntilHandoff(document).map(step => [step.id, step.kind]),
    [
      ["goto-cert-center", "goto"],
      ["goto-issue", "goto"],
    ],
  );
  assert.deepEqual(
    handoffSteps(document).map(step => step.id),
    [
      "human-terms",
      "human-identity",
      "human-account-secret",
      "human-otp",
      "human-fee",
      "human-storage",
      "human-security-uac",
      "human-cert-secret",
      "human-final",
    ],
  );
  assert.equal(document.steps.every(step => !isHandoffStep(step) || step.kind === "human"), true);
  assert.deepEqual(grantsUsed(document), ["ui.read", "ui.control"]);
});

test("page prefix stops at the first step a page cannot run; later page steps are not pulled forward", () => {
  const osTypeThenClick = documentOf([
    { id: "open", kind: "goto", url: "https://example.test/a", effect: "navigate" },
    { id: "type-os", kind: "type", target: "입력", effect: "input" },
    { id: "next", kind: "click", locator: "role=button[name=다음]", effect: "navigate" },
    { id: "person", kind: "human" },
  ]);
  assert.deepEqual(pageStepsUntilHandoff(osTypeThenClick).map(step => step.id), ["open"]);

  const locatorlessClick = documentOf([
    { id: "open", kind: "goto", url: "https://example.test/a", effect: "navigate" },
    { id: "wait", kind: "waitFor", locator: "#ready" },
    { id: "tap", kind: "click", target: "다음", effect: "navigate" },
    { id: "fill", kind: "fill", locator: "#q", text: "x", effect: "input" },
  ]);
  assert.deepEqual(pageStepsUntilHandoff(locatorlessClick).map(step => step.id), ["open", "wait"]);

  const bareRead = documentOf([
    { id: "look", kind: "read" },
    { id: "open", kind: "goto", url: "https://example.test/a", effect: "navigate" },
  ]);
  assert.deepEqual(pageStepsUntilHandoff(bareRead), []);

  const handoffFirst = documentOf([
    { id: "pay", kind: "payment", target: "결제하기" },
    { id: "open", kind: "goto", url: "https://example.test/a", effect: "navigate" },
  ]);
  assert.deepEqual(pageStepsUntilHandoff(handoffFirst), []);
  assert.deepEqual(handoffSteps(handoffFirst).map(step => step.id), ["pay"]);
});
