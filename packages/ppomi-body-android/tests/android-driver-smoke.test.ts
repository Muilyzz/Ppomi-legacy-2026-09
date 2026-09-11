import assert from "node:assert/strict";
import { test } from "node:test";
import {
  FixedPermissionGate,
  OsSurface,
  Runtime,
  type Playbook,
} from "../../ppomi-body/src/index.ts";
import {
  AndroidAdapterError,
  AndroidDriver,
  FixtureAndroidNativeTools,
  fixtureToolNames,
  type FixtureAndroidWindow,
} from "../src/index.ts";

const window: FixtureAndroidWindow = {
  appLabel: "Demo App",
  packageName: "com.ppomi.androidtarget",
  nodes: [
    { text: "Demo App", clickable: false, editable: false },
    { text: "Next", clickable: true, editable: false },
    { text: "Name", clickable: false, editable: true },
    { text: "Password", clickable: false, editable: true, password: true },
  ],
};

const smoke: Playbook = {
  id: "fixture-android-smoke",
  steps: [
    { id: "focus-app", kind: "focus", target: "Demo App" },
    { id: "open-next", kind: "click", target: "Next", effect: "navigate" },
    { id: "fill-name", kind: "type", target: "Name", text: "fixture", effect: "input" },
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

const offPortTools = ["android_tap", "android_swipe", "android_key", "android_status"];

test("smoke: the runtime core drives android_* tools through ppomi-body-android", async () => {
  const tools = new FixtureAndroidNativeTools(window);
  const runtime = new Runtime(
    new OsSurface(new AndroidDriver(tools)),
    new FixedPermissionGate(["ui.read", "ui.control"]),
  );
  const result = await runtime.run(smoke);

  assert.equal(result.status, "completed");
  assert.equal(result.stopReason, null);
  assert.deepEqual(result.evidence.map(row => row.outcome), ["ok", "ok", "ok", "ok"]);
  assert.deepEqual(result.stepResults.map(row => row.driver), [
    "os-android",
    "os-android",
    "os-android",
    "os-android",
  ]);
  assert.deepEqual(fixtureToolNames(tools.calls), [
    "android_screen",
    "android_open",
    "android_screen",
    "android_click",
    "android_screen",
    "android_type",
    "android_screen",
  ]);
  assert.deepEqual(tools.calls.filter(call => call.name === "android_open"), [
    { name: "android_open", args: { packageName: "com.ppomi.androidtarget" } },
  ]);
  assert.equal(
    tools.calls.some(call => call.name === "android_click" && call.args.nodeId === "fixture-2:1"),
    true,
  );
  assert.deepEqual(tools.calls.filter(call => call.name === "android_type"), [
    { name: "android_type", args: { nodeId: "fixture-3:2", text: "fixture" } },
  ]);
  assert.equal(tools.calls.some(call => approvalTools.includes(call.name)), false);
  assert.equal(tools.calls.some(call => offPortTools.includes(call.name)), false);
  assert.doesNotMatch(JSON.stringify(result), /approv/i);
  assert.equal("deviceApproved" in result, false);
});

test("missing click target does not call android_click", () => {
  const tools = new FixtureAndroidNativeTools(window);
  const driver = new AndroidDriver(tools);
  driver.readScreen();
  assert.throws(() => driver.click("Submit"), error =>
    error instanceof AndroidAdapterError && error.code === "target_not_on_screen");
  assert.deepEqual(fixtureToolNames(tools.calls), ["android_screen"]);
});

test("android_open refuses a package outside the allowlist", () => {
  const tools = new FixtureAndroidNativeTools(window);
  assert.throws(() => tools.android_open({ packageName: "com.android.vending" }), error =>
    error instanceof AndroidAdapterError && error.code === "app_not_allowed");

  const driver = new AndroidDriver(tools);
  driver.readScreen();
  assert.throws(() => driver.focus("com.android.vending"), error =>
    error instanceof AndroidAdapterError && error.code === "app_not_found");
  assert.deepEqual(fixtureToolNames(tools.calls), ["android_open", "android_screen"]);
});

test("type refuses a password field and does not call android_type", () => {
  const tools = new FixtureAndroidNativeTools(window);
  const driver = new AndroidDriver(tools);
  driver.readScreen();
  assert.throws(() => driver.type("Password", "secret"), error =>
    error instanceof AndroidAdapterError && error.code === "protected_action");
  assert.deepEqual(fixtureToolNames(tools.calls), ["android_screen"]);
});
