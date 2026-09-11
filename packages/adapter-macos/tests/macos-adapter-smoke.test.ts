import assert from "node:assert/strict";
import { test } from "node:test";
import {
  FixedPermissionGate,
  PlaybookRuntime,
  type Playbook,
} from "../../playbook-runtime/src/index.ts";
import {
  FixtureMacosNativeTools,
  MacosAdapter,
  fixtureToolNames,
  type FixtureMacosWindow,
} from "../src/index.ts";

const window: FixtureMacosWindow = {
  appLabel: "Demo App",
  url: "https://example.test/fixture",
  nodes: [
    { text: "Demo App", clickable: false, editable: false },
    { text: "Next", clickable: true, editable: false },
    { text: "Name", clickable: false, editable: true },
  ],
};

const smoke: Playbook = {
  id: "fixture-macos-smoke",
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

test("smoke: playbook-runtime drives Mac native tools through adapter-macos", () => {
  const tools = new FixtureMacosNativeTools(window);
  const runtime = new PlaybookRuntime(
    new MacosAdapter(tools),
    new FixedPermissionGate(["ui.read", "ui.control"]),
  );
  const result = runtime.run(smoke);

  assert.equal(result.status, "completed");
  assert.equal(result.stopReason, null);
  assert.deepEqual(result.evidence.map(row => row.outcome), ["ok", "ok", "ok", "ok"]);
  assert.deepEqual(fixtureToolNames(tools.calls), [
    "screen_read",
    "browser_open",
    "screen_read",
    "ui_tap",
    "screen_read",
    "ui_type",
    "screen_read",
  ]);
  assert.deepEqual(tools.calls.filter(call => call.name === "browser_open"), [
    { name: "browser_open", args: { app: "Demo App" } },
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
  const tools = new FixtureMacosNativeTools(window);
  const adapter = new MacosAdapter(tools);
  adapter.readScreen();
  assert.throws(() => adapter.click("Submit"), error =>
    error instanceof Error && "code" in error && error.code === "target_not_on_screen");
  assert.deepEqual(fixtureToolNames(tools.calls), ["screen_read"]);
});
