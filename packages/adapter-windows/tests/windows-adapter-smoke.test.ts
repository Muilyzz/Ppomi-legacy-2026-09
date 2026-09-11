import assert from "node:assert/strict";
import { test } from "node:test";
import {
  FixedPermissionGate,
  PlaybookRuntime,
  type Playbook,
} from "../../playbook-runtime/src/index.ts";
import {
  FixtureWindowsExecutorTools,
  WindowsAdapter,
  fixtureToolNames,
  type FixtureWindowsWindow,
} from "../src/index.ts";

const window: FixtureWindowsWindow = {
  appLabel: "Demo App",
  packageName: "win:1:1",
  nodes: [
    { text: "Demo App", clickable: false, editable: false },
    { text: "Next", clickable: true, editable: false },
    { text: "Name", clickable: false, editable: true },
  ],
};

const smoke: Playbook = {
  id: "fixture-windows-smoke",
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

test("smoke: playbook-runtime drives Windows executor tools through adapter-windows", () => {
  const tools = new FixtureWindowsExecutorTools(window);
  const runtime = new PlaybookRuntime(
    new WindowsAdapter(tools),
    new FixedPermissionGate(["ui.read", "ui.control"]),
  );
  const result = runtime.run(smoke);

  assert.equal(result.status, "completed");
  assert.equal(result.stopReason, null);
  assert.deepEqual(result.evidence.map(row => row.outcome), ["ok", "ok", "ok", "ok"]);
  assert.deepEqual(fixtureToolNames(tools.calls), [
    "screen_read",
    "app_open",
    "screen_read",
    "ui_tap",
    "screen_read",
    "ui_type",
    "screen_read",
  ]);
  assert.deepEqual(tools.calls.filter(call => call.name === "app_open"), [
    { name: "app_open", args: { target: "Demo App" } },
  ]);
  assert.equal(tools.calls.some(call => call.name === "ui_tap" && call.args.nodeId === "fixture-2:1"), true);
  assert.deepEqual(tools.calls.filter(call => call.name === "ui_type"), [
    { name: "ui_type", args: { nodeId: "fixture-3:2", text: "fixture" } },
  ]);
  assert.equal(tools.calls.some(call => approvalTools.includes(call.name)), false);
  assert.doesNotMatch(JSON.stringify(result), /approv/i);
  assert.equal("deviceApproved" in result, false);
});

test("missing click target does not call ui_tap", () => {
  const tools = new FixtureWindowsExecutorTools(window);
  const adapter = new WindowsAdapter(tools);
  adapter.readScreen();
  assert.throws(() => adapter.click("Submit"), error =>
    error instanceof Error && "code" in error && error.code === "target_not_on_screen");
  assert.deepEqual(fixtureToolNames(tools.calls), ["screen_read"]);
});
