import assert from "node:assert/strict";
import { test } from "node:test";
import {
  FixtureWindowsExecutorTools,
  WINDOWS_SNAPSHOT_TTL_MS,
  WindowsAdapter,
  fixtureToolNames,
  snapshotIdOf,
  type FixtureWindowsWindow,
} from "../src/index.ts";

const window: FixtureWindowsWindow = {
  appLabel: "Demo App",
  packageName: "win:1:1",
  nodes: [
    { text: "Next", clickable: true, editable: false, role: "ControlType.Button" },
    { text: "Name", clickable: false, editable: true, role: "ControlType.Edit" },
  ],
};

function code(error: unknown): string | undefined {
  return error instanceof Error && "code" in error ? String(error.code) : undefined;
}

test("nodeId is <snapshotId>:<index> and only the latest snapshot is addressable", () => {
  const tools = new FixtureWindowsExecutorTools(window);
  const first = tools.screen_read();
  assert.equal(snapshotIdOf(first.nodes[0]!.id), first.snapshotId);
  const second = tools.screen_read();
  assert.notEqual(first.snapshotId, second.snapshotId);
  assert.throws(() => tools.ui_tap({ nodeId: first.nodes[0]!.id }), error => code(error) === "stale_screen");
  assert.deepEqual(tools.ui_tap({ nodeId: second.nodes[0]!.id }), { invoked: true, requiresScreenRead: true });
});

test("every ui_tap / ui_type invalidates the snapshot it was addressed against", () => {
  const tools = new FixtureWindowsExecutorTools(window);
  const screen = tools.screen_read();
  assert.deepEqual(tools.ui_type({ nodeId: screen.nodes[1]!.id, text: "x" }), { typed: true, requiresScreenRead: true });
  assert.throws(() => tools.ui_tap({ nodeId: screen.nodes[0]!.id }), error => code(error) === "stale_screen");
  const fresh = tools.screen_read();
  assert.deepEqual(tools.ui_tap({ nodeId: fresh.nodes[0]!.id }), { invoked: true, requiresScreenRead: true });
});

test("a snapshot older than the measured TTL is rejected with stale_screen", () => {
  let clock = 1_000;
  const tools = new FixtureWindowsExecutorTools(window, { now: () => clock });
  const screen = tools.screen_read();
  clock += WINDOWS_SNAPSHOT_TTL_MS + 1;
  assert.throws(() => tools.ui_type({ nodeId: screen.nodes[1]!.id, text: "late" }), error => code(error) === "stale_screen");
  const fresh = tools.screen_read();
  assert.equal(tools.ui_type({ nodeId: fresh.nodes[1]!.id, text: "ok" }).typed, true);
});

test("non-invokable / non-editable nodes fail like the executor: protected_action", () => {
  const tools = new FixtureWindowsExecutorTools(window);
  const screen = tools.screen_read();
  assert.throws(() => tools.ui_tap({ nodeId: screen.nodes[1]!.id }), error => code(error) === "protected_action");
  assert.throws(() => tools.ui_type({ nodeId: screen.nodes[0]!.id, text: "no" }), error => code(error) === "protected_action");
});

test("WindowsAdapter re-reads before each addressed action, so invalidation never trips it", () => {
  const tools = new FixtureWindowsExecutorTools(window);
  const adapter = new WindowsAdapter(tools);
  adapter.focus("Demo App");
  adapter.click("Next");
  adapter.type("Name", "fixture");
  adapter.click("Next");
  assert.deepEqual(fixtureToolNames(tools.calls), [
    "app_open",
    "screen_read",
    "ui_tap",
    "screen_read",
    "ui_type",
    "screen_read",
    "ui_tap",
  ]);
});
