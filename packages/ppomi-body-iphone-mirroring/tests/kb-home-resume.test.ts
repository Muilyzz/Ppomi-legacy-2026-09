import assert from "node:assert/strict";
import { test } from "node:test";
import {
  FixedPermissionGate,
  OsSurface,
  Runtime,
  type Playbook,
} from "../../ppomi-body/src/index.ts";
import {
  FixtureIphoneMirroringTools,
  IPHONE_HOME_KEY,
  IphoneMirroringDriver,
  fixtureToolNames,
  type FixtureIphoneMirroringScreen,
} from "../src/index.ts";

const screen: FixtureIphoneMirroringScreen = {
  appLabel: "KB스타기업뱅킹",
  rows: [
    { text: "KB스타기업뱅킹", tappable: false, editable: false },
    { text: "계좌조회", tappable: true, editable: false },
    { text: "계좌번호", tappable: false, editable: false },
    { text: "****7890", tappable: false, editable: false },
  ],
};

const kb: Playbook = {
  id: "kb-star-biz-iphone",
  steps: [
    { id: "go-home", kind: "key", target: IPHONE_HOME_KEY, effect: "navigate" },
    { id: "open-kb", kind: "focus", target: "KB스타기업뱅킹" },
    { id: "open-accounts", kind: "click", target: "계좌조회", effect: "navigate" },
    { id: "read-account", kind: "read", require: { screen: ["계좌번호"] } },
  ],
};

function runtime(tools: FixtureIphoneMirroringTools) {
  return new Runtime(
    new OsSurface(new IphoneMirroringDriver(tools)),
    new FixedPermissionGate(["ui.read", "ui.control"]),
  );
}

test("phone Home is phone_key home (CLI: phone key home → ⌘1 → SpringBoard)", () => {
  assert.equal(IPHONE_HOME_KEY, "home");
});

test("cold start sends Home then proceeds; resume-after-fail skips Home", async () => {
  const coldTools = new FixtureIphoneMirroringTools(screen);
  const cold = await runtime(coldTools).run(kb);
  assert.equal(cold.status, "completed");
  assert.deepEqual(cold.stepResults.map(row => row.stepId), [
    "go-home",
    "open-kb",
    "open-accounts",
    "read-account",
  ]);
  assert.deepEqual(
    coldTools.calls.filter(call => call.name === "phone_key"),
    [{ name: "phone_key", args: { name: "home" } }],
  );
  assert.equal(fixtureToolNames(coldTools.calls).indexOf("phone_key"), 1);
  assert.ok(fixtureToolNames(coldTools.calls).indexOf("phone_open") > fixtureToolNames(coldTools.calls).indexOf("phone_key"));
  assert.doesNotMatch(JSON.stringify(cold), /001234567890|\d{12,14}/);

  const failedTools = new FixtureIphoneMirroringTools({
    ...screen,
    rows: screen.rows.filter(row => row.text !== "계좌조회"),
  });
  const failed = await runtime(failedTools).run(kb);
  assert.equal(failed.status, "stopped");
  assert.equal(failed.stepResults.find(row => row.stepId === "open-accounts")?.status, "failed");
  assert.equal(failedTools.calls.some(call => call.name === "phone_key"), true);

  const resumeTools = new FixtureIphoneMirroringTools(screen);
  const resume = await runtime(resumeTools).run(kb, { fromStep: "open-accounts" });
  assert.equal(resume.status, "completed");
  assert.deepEqual(resume.stepResults.map(row => row.stepId), ["open-accounts", "read-account"]);
  assert.equal(resumeTools.calls.some(call => call.name === "phone_key"), false);
  assert.deepEqual(resumeTools.calls.filter(call => call.name === "phone_tap"), [
    { name: "phone_tap", args: { text: "계좌조회" } },
  ]);
  assert.doesNotMatch(JSON.stringify(resume), /001234567890|\d{12,14}/);
});
