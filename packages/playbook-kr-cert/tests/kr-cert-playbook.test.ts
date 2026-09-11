import assert from "node:assert/strict";
import { test } from "node:test";
import {
  FixtureWindowsExecutorTools,
  WindowsAdapter,
  fixtureToolNames,
} from "../../adapter-windows/src/index.ts";
import {
  FixedPermissionGate,
  PlaybookRuntime,
} from "../../playbook-runtime/src/index.ts";
import {
  krCertPlaybook,
  krCertPreparePlaybook,
  krCertRuntimePlaybook,
  krCertWindowsWindow,
} from "../src/index.ts";

function runtime() {
  const tools = new FixtureWindowsExecutorTools(krCertWindowsWindow);
  const playbookRuntime = new PlaybookRuntime(
    new WindowsAdapter(tools),
    new FixedPermissionGate(["ui.read", "ui.control"]),
  );
  return { tools, playbookRuntime };
}

test("playbook-kr-cert content includes payment and submit steps and no device-approval fields", () => {
  const kinds = krCertPlaybook.steps.map(step => step.kind);
  assert.equal(krCertPlaybook.id, "playbook-kr-cert");
  assert.equal(kinds.includes("payment"), true);
  assert.equal(kinds.includes("submit"), true);
  assert.equal(krCertPlaybook.steps.some(step => step.target === "결제하기"), true);
  assert.equal(krCertPlaybook.steps.some(step => step.target === "제출"), true);
  const raw = JSON.stringify(krCertPlaybook);
  assert.doesNotMatch(raw, /approv|deviceApproved|pendingApproval/i);
  assert.doesNotMatch(raw, /주민등록|인증서 비밀번호|deviceApproved/i);
});

test("prepare steps run through playbook-runtime and adapter-windows fixture", () => {
  const { tools, playbookRuntime } = runtime();
  const result = playbookRuntime.run(krCertPreparePlaybook());

  assert.equal(result.status, "completed");
  assert.equal(result.stopReason, null);
  assert.deepEqual(result.evidence.map(row => row.outcome), ["ok", "ok", "ok", "ok", "ok"]);
  assert.deepEqual(fixtureToolNames(tools.calls), [
    "screen_read",
    "app_open",
    "screen_read",
    "screen_read",
    "ui_tap",
    "screen_read",
    "ui_type",
    "screen_read",
  ]);
  assert.deepEqual(tools.calls.filter(call => call.name === "app_open"), [
    { name: "app_open", args: { target: "인증서 발급" } },
  ]);
  assert.deepEqual(tools.calls.filter(call => call.name === "ui_tap"), [
    { name: "ui_tap", args: { nodeId: "fixture-3:2" } },
  ]);
  assert.deepEqual(tools.calls.filter(call => call.name === "ui_type"), [
    { name: "ui_type", args: { nodeId: "fixture-4:3", text: "개인사업자" } },
  ]);
});

test("payment and submit clicks are fail-closed and never reach ui_tap", () => {
  const { tools, playbookRuntime } = runtime();
  const result = playbookRuntime.run(krCertRuntimePlaybook());

  assert.equal(result.status, "stopped");
  assert.equal(result.stopReason, "protected_action");
  const pay = result.evidence.at(-1);
  assert.equal(pay?.stepId, "pay-certificate");
  assert.equal(pay?.outcome, "protected_action");
  assert.equal(pay?.note, "protected target: 결제하기");
  assert.equal(result.evidence.some(row => row.stepId === "submit-application"), false);
  assert.equal(tools.calls.some(call => call.name === "ui_tap" && call.args.nodeId.endsWith(":5")), false);
  assert.equal(tools.calls.some(call => call.name === "ui_tap" && call.args.nodeId.endsWith(":6")), false);
  assert.deepEqual(tools.calls.filter(call => call.name === "ui_tap"), [
    { name: "ui_tap", args: { nodeId: "fixture-3:2" } },
  ]);
  assert.doesNotMatch(JSON.stringify(result), /approv/i);
});
