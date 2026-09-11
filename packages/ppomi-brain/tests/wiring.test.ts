import assert from "node:assert/strict";
import { test } from "node:test";
import {
  bodyFromPlaybookRuntime,
  type BodyRunResult,
  type LegacyPlaybookRunner,
} from "../src/index.ts";
import { narrowGrant, payPath } from "./fixtures.ts";

function sync(result: BodyRunResult | Promise<BodyRunResult>): BodyRunResult {
  if (result instanceof Promise) throw new Error("expected sync body result");
  return result;
}

test("playbook-runtime wiring maps a protected payment click to HITL stop", () => {
  const runtime: LegacyPlaybookRunner = {
    run(playbook) {
      assert.equal(playbook.steps.at(-1)?.kind, "click");
      assert.equal(playbook.steps.at(-1)?.target, "결제하기");
      return {
        status: "stopped",
        stopReason: "protected_action",
        evidence: [
          { stepId: "read-bill", outcome: "ok", note: "read" },
          { stepId: "fill-amount", outcome: "ok", note: "typed" },
          { stepId: "submit-pay", outcome: "protected_action", note: "protected target: 결제하기" },
        ],
      };
    },
  };

  const result = sync(bodyFromPlaybookRuntime(runtime).run({
    path: payPath,
    grant: narrowGrant(payPath),
  }));

  assert.equal(result.status, "stopped");
  assert.equal(result.stopReason, "protected");
  assert.equal(result.steps.at(-1)?.effect, "financial_submit");
  assert.equal(result.steps.at(-1)?.status, "protected");
});

test("playbook-runtime wiring will not promote a payment ok into a body success", () => {
  const runtime: LegacyPlaybookRunner = {
    run() {
      return {
        status: "completed",
        stopReason: null,
        evidence: [
          { stepId: "read-bill", outcome: "ok", note: "read" },
          { stepId: "fill-amount", outcome: "ok", note: "typed" },
          { stepId: "submit-pay", outcome: "ok", note: "clicked pay" },
        ],
      };
    },
  };

  const result = sync(bodyFromPlaybookRuntime(runtime).run({
    path: payPath,
    grant: narrowGrant(payPath),
  }));

  assert.equal(result.status, "stopped");
  assert.equal(result.stopReason, "protected");
  assert.equal(result.steps.some(step => step.effect === "financial_submit" && step.status === "ok"), false);
});
