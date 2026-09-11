import assert from "node:assert/strict";
import { test } from "node:test";
import {
  grantsUsed,
  handoffSteps,
  isHandoffStep,
  loadPath,
  pageStepsUntilHandoff,
} from "../src/index.ts";

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
