import assert from "node:assert/strict";
import { test } from "node:test";
import {
  FixedPermissionGate,
  PlaybookRuntime,
  dumpStepResults,
  parseStepResult,
  type Playbook,
  type StepResult,
} from "../../playbook-runtime/src/index.ts";
import {
  FixtureIphoneMirroringTools,
  IphoneMirroringAdapter,
  IphoneMirroringAdapterError,
  fixtureToolNames,
  type FixtureIphoneMirroringScreen,
} from "../src/index.ts";

const screen: FixtureIphoneMirroringScreen = {
  appLabel: "Demo App",
  rows: [
    { text: "Demo App", tappable: false, editable: false },
    { text: "Next", tappable: true, editable: false },
    { text: "Name", tappable: false, editable: true },
  ],
};

const smoke: Playbook = {
  id: "fixture-iphone-mirroring-smoke",
  steps: [
    { id: "focus-app", kind: "focus", target: "Demo App" },
    { id: "open-next", kind: "click", target: "Next" },
    { id: "fill-name", kind: "type", target: "Name", text: "fixture" },
    { id: "confirm-screen", kind: "read", require: { screen: ["Demo App", "Next"] } },
  ],
};

const approvalTools = [
  "beginSignIn",
  "completeSignIn",
  "configureDevice",
  "refreshAccount",
  "signOut",
  "setControlApps",
];

const macosDesktopTools = ["browser_open", "screen_read", "ui_tap", "ui_type"];

test("smoke: playbook-runtime drives phone_* tools through adapter-iphone-mirroring", () => {
  const tools = new FixtureIphoneMirroringTools(screen);
  const adapter = new IphoneMirroringAdapter(tools);
  const runtime = new PlaybookRuntime(
    adapter,
    new FixedPermissionGate(["ui.read", "ui.control"]),
  );
  const result = runtime.run(smoke);

  assert.equal(result.status, "completed");
  assert.equal(result.stopReason, null);
  assert.deepEqual(result.evidence.map(row => row.outcome), ["ok", "ok", "ok", "ok"]);
  assert.deepEqual(fixtureToolNames(tools.calls), [
    "phone_screen",
    "phone_open",
    "phone_screen",
    "phone_tap",
    "phone_screen",
    "phone_type",
    "phone_screen",
  ]);
  assert.deepEqual(tools.calls.filter(call => call.name === "phone_open"), [
    { name: "phone_open", args: { app: "Demo App" } },
  ]);
  assert.deepEqual(tools.calls.filter(call => call.name === "phone_tap"), [
    { name: "phone_tap", args: { text: "Next" } },
  ]);
  assert.deepEqual(tools.calls.filter(call => call.name === "phone_type"), [
    { name: "phone_type", args: { text: "fixture" } },
  ]);
  assert.equal(tools.calls.some(call => call.name === "phone_key"), false);
  assert.equal(tools.calls.some(call => call.name === "phone_scroll"), false);
  assert.equal(tools.calls.some(call => approvalTools.includes(call.name)), false);
  assert.equal(tools.calls.some(call => macosDesktopTools.includes(call.name)), false);
  assert.doesNotMatch(JSON.stringify(result), /approv/i);
  assert.equal("deviceApproved" in result, false);
  assert.equal("goto" in adapter, false);
  assert.equal("readPage" in adapter, false);
});

test("missing click target does not call phone_tap", () => {
  const tools = new FixtureIphoneMirroringTools(screen);
  const adapter = new IphoneMirroringAdapter(tools);
  adapter.readScreen();
  assert.throws(
    () => adapter.click("Submit"),
    error => error instanceof IphoneMirroringAdapterError && error.code === "target_not_on_screen",
  );
  assert.deepEqual(fixtureToolNames(tools.calls), ["phone_screen"]);
});

test("fixture phone_key and phone_scroll exist; OsAdapter does not call them", () => {
  const tools = new FixtureIphoneMirroringTools(screen);
  assert.deepEqual(tools.phone_key({ name: "home" }), { sent: true });
  assert.deepEqual(tools.phone_scroll({ dy: -430 }), { scrolled: true });
  assert.deepEqual(fixtureToolNames(tools.calls), ["phone_key", "phone_scroll"]);
});

test("StepResult adapter value phone is reused, not invented", () => {
  const step: StepResult = {
    stepId: "open-next",
    playbookId: "fixture-iphone-mirroring-smoke",
    adapter: "phone",
    action: "click",
    status: "ok",
    attempt: "executed",
    target: { kind: "accessibility", name: "Next" },
    observation: { summary: "phone_tap Next on iPhone Mirroring" },
    timingMs: 20,
  };

  assert.equal(parseStepResult(step).adapter, "phone");
  assert.match(dumpStepResults([step]), /"adapter": "phone"/);
  assert.throws(() => parseStepResult({ ...step, adapter: "os-iphone" }), /adapter must be/);
  assert.throws(() => parseStepResult({ ...step, adapter: "mirroring" }), /adapter must be/);
  assert.equal(parseStepResult({ ...step, adapter: "os-macos" }).adapter, "os-macos");
});
