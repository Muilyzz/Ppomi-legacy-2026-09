import assert from "node:assert/strict";
import { dirname, join } from "node:path";
import { test } from "node:test";
import { fileURLToPath } from "node:url";
import { LiveWindowsExecutorTools, WindowsAdapter, WindowsAdapterError, type LiveWindowsExecutorOptions } from "../src/index.ts";

const fake = join(dirname(fileURLToPath(import.meta.url)), "fixtures", "fake-ppomi-executor.mjs");

function start(extra: Partial<LiveWindowsExecutorOptions> = {}): LiveWindowsExecutorTools {
  return LiveWindowsExecutorTools.start({
    executorPath: "unused-when-launch-is-given",
    launch: { command: process.execPath, args: [fake] },
    requestTimeoutMs: 10_000,
    ...extra,
  });
}

function code(error: unknown): string | undefined {
  return error instanceof WindowsAdapterError ? error.code : undefined;
}

test("live bridge: idle-only setControlApps ordering, then app_open / screen_read / ui_type / ui_tap", () => {
  const tools = start();
  try {
    const running = tools.listApps("");
    assert.deepEqual(running, { apps: [{ label: "fakeapp", packageName: "win:4242:1", allowed: false }], truncated: false });
    // allowApps must pause the active session first; the fake answers protected_action otherwise.
    assert.deepEqual(tools.allowApps(["win:4242:1"]), { updated: true });
    assert.deepEqual(tools.app_open({ target: "win:4242:1" }), { packageName: "win:4242:1", activated: true });

    const first = tools.screen_read();
    assert.equal(first.appLabel, "fakeapp");
    assert.deepEqual(first.nodes.map(node => node.role), ["ControlType.Window", "ControlType.Edit", "ControlType.Button", "ControlType.Text"]);
    const input = first.nodes.find(node => node.editable);
    assert.ok(input);
    assert.deepEqual(tools.ui_type({ nodeId: input.id, text: "hello" }), { typed: true, requiresScreenRead: true });
    assert.equal(code(assertThrows(() => tools.ui_tap({ nodeId: first.nodes[2]!.id }))), "stale_screen");

    const second = tools.screen_read();
    assert.ok(second.nodes.some(node => node.text === "Name hello"));
    assert.deepEqual(tools.ui_tap({ nodeId: second.nodes[2]!.id }), { invoked: true, requiresScreenRead: true });
    assert.ok(tools.screen_read().nodes.some(node => node.text === "tapped"));
  } finally {
    tools.close();
  }
});

test("live bridge: executor error codes pass through unchanged", () => {
  const tools = start();
  try {
    assert.equal(code(assertThrows(() => tools.app_open({ target: "win:4242:1" }))), "app_not_allowed");
    tools.allowApps(["win:4242:1"]);
    const screen = tools.screen_read();
    assert.equal(code(assertThrows(() => tools.ui_tap({ nodeId: screen.nodes[1]!.id }))), "protected_action");
  } finally {
    tools.close();
  }
});

test("live bridge: a nodeId from an older or expired snapshot is refused before reaching the executor", () => {
  let clock = 0;
  const tools = start({ now: () => clock, snapshotTtlMs: 1_000 });
  try {
    tools.allowApps(["win:4242:1"]);
    const stale = tools.screen_read();
    const fresh = tools.screen_read();
    assert.equal(code(assertThrows(() => tools.ui_tap({ nodeId: stale.nodes[2]!.id }))), "stale_screen");
    clock += 1_001;
    assert.equal(code(assertThrows(() => tools.ui_tap({ nodeId: fresh.nodes[2]!.id }))), "stale_screen");
    assert.equal(tools.ui_tap({ nodeId: tools.screen_read().nodes[2]!.id }).invoked, true);
  } finally {
    tools.close();
  }
});

test("live bridge: WindowsAdapter runs focus / type / click / read over the real protocol shape", () => {
  const tools = start();
  try {
    tools.allowApps(["win:4242:1"]);
    const adapter = new WindowsAdapter(tools);
    adapter.focus("win:4242:1");
    adapter.type("Name", "adapter");
    adapter.click("Go");
    const screen = adapter.readScreen();
    assert.equal(screen.title, "fakeapp");
    assert.ok(screen.texts.includes("Name adapter"));
    assert.ok(screen.texts.includes("tapped"));
  } finally {
    tools.close();
  }
});

test("live bridge: a missing executor binary fails to start with native_unavailable", () => {
  assert.equal(code(assertThrows(() => LiveWindowsExecutorTools.start({ executorPath: join(dirname(fake), "does-not-exist.exe") }))), "native_unavailable");
});

function assertThrows(block: () => unknown): unknown {
  try {
    block();
  } catch (error) {
    return error;
  }
  assert.fail("expected an error");
}
