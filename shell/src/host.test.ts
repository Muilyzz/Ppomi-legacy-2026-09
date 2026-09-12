import assert from "node:assert/strict";
import { test } from "node:test";
import { MacosAdapterError, type MacScreenNode } from "../../packages/ppomi-body-macos/src/index.ts";
import { homePath, parseArgs, parseBodyKind, runLiveMacos, runSpine, type LiveMacTools, type RunCapture } from "./host.ts";

const EXAMPLE_NODES: readonly MacScreenNode[] = [
  { id: "n0", text: "Example Domain", clickable: false, editable: false },
  { id: "n1", text: "More information...", clickable: true, editable: false },
];

interface FakeLiveOptions {
  readonly trusted?: boolean;
  readonly nodes?: readonly MacScreenNode[];
  readonly openError?: Error;
}

function fakeLiveTools(options: FakeLiveOptions = {}): LiveMacTools & { readonly taps: string[] } {
  const nodes = options.nodes ?? EXAMPLE_NODES;
  const taps: string[] = [];
  return {
    app: "Safari",
    taps,
    trusted: () => options.trusted ?? true,
    browser_open: () => {
      if (options.openError !== undefined) throw options.openError;
      return { opened: true, app: "Safari" };
    },
    screen_read: () => ({ snapshotId: "fake-1", appLabel: "Safari", nodes, truncated: false }),
    ui_tap: ({ nodeId }) => {
      taps.push(nodeId);
      return { invoked: true };
    },
    ui_type: () => ({ typed: true }),
  };
}

test("macos fixture 1-step reaches ppomi-body-macos through brain and keeps the core RunResult", async () => {
  const result = await runSpine({ intent: "다음", body: "macos", live: false });
  assert.equal(result.status, "completed");
  assert.equal(result.pathId, "path-home-next");
  assert.equal(result.bodyKind, "macos");
  assert.equal(result.body?.status, "completed");
  assert.equal(result.body?.steps[0]?.status, "ok");
  assert.equal(result.run?.status, "completed");
  assert.equal(result.run?.stepResults[0]?.driver, "os-macos");
  assert.equal(result.run?.stepResults[0]?.attempt, "executed");
  assert.equal(result.run?.stepResults[0]?.code, undefined);
  assert.match(result.hook, /PPOMI_BODY_LIVE=1/);
});

test("unknown intent never calls body", async () => {
  const result = await runSpine({ intent: "no-such-path", body: "macos", live: false });
  assert.equal(result.status, "path_not_found");
  assert.equal(result.body, null);
  assert.equal(result.run, null);
});

test("windows and android fixtures share the same spine IPC", async () => {
  const windows = await runSpine({ intent: "browse", body: "windows", live: false });
  const android = await runSpine({ intent: "home", body: "android", live: false });
  assert.equal(windows.status, "completed");
  assert.equal(android.status, "completed");
  assert.equal(windows.bodyKind, "windows");
  assert.equal(android.bodyKind, "android");
  assert.equal(windows.run?.stepResults[0]?.driver, "os-windows");
  assert.equal(android.run?.stepResults[0]?.driver, "os-android");
});

test("live macos off-darwin stops as needs_human, never completed", async () => {
  if (process.platform === "darwin") return;
  const result = await runSpine({ intent: "다음", body: "macos", live: true });
  assert.equal(result.status, "needs_human");
  assert.equal(result.body?.status, "stopped");
  assert.equal(result.body?.stopReason, "needs_human");
  assert.equal(result.body?.steps[0]?.status, "needs_human");
  assert.equal(result.run, null);
  assert.equal(result.live, true);
  assert.match(result.note, /needs a Mac/);
});

test("live windows / android are not wired through the shell: stopped/failed, fixture not run", async () => {
  const windows = await runSpine({ intent: "다음", body: "windows", live: true });
  assert.equal(windows.status, "failed");
  assert.equal(windows.body?.status, "stopped");
  assert.equal(windows.body?.stopReason, "failed");
  assert.equal(windows.run, null);
  assert.match(windows.note, /MZZ-55b/);
  const android = await runSpine({ intent: "다음", body: "android", live: true });
  assert.equal(android.status, "failed");
  assert.equal(android.run, null);
  assert.match(android.note, /MZZ-55c/);
});

test("live macos: Accessibility denied is grant_denied and nothing is opened or tapped", async () => {
  const tools = fakeLiveTools({ trusted: false });
  const capture: RunCapture = { run: null };
  const result = await runLiveMacos(homePath, tools, capture);
  assert.equal(result.status, "stopped");
  assert.equal(result.stopReason, "grant_denied");
  assert.equal(result.steps[0]?.status, "grant_denied");
  assert.match(result.steps[0]?.note ?? "", /Accessibility denied/);
  assert.equal(capture.run, null);
  assert.deepEqual(tools.taps, []);
});

test("live macos: front window without the example.com link is needs_human, no other click", async () => {
  const tools = fakeLiveTools({
    nodes: [
      { id: "n0", text: "Some other page", clickable: false, editable: false },
      { id: "n1", text: "Buy now", clickable: true, editable: false },
    ],
  });
  const capture: RunCapture = { run: null };
  const result = await runLiveMacos(homePath, tools, capture);
  assert.equal(result.status, "stopped");
  assert.equal(result.stopReason, "needs_human");
  assert.match(result.steps[0]?.note ?? "", /More information/);
  assert.equal(capture.run, null);
  assert.deepEqual(tools.taps, []);
});

test("live macos: a thrown tool error is failed with its code, and URLs in the message are redacted", async () => {
  const tools = fakeLiveTools({
    openError: new MacosAdapterError("accessibility", "Not authorized https://example.com/?session=abc123 (-1743)"),
  });
  const capture: RunCapture = { run: null };
  const result = await runLiveMacos(homePath, tools, capture);
  assert.equal(result.status, "stopped");
  assert.equal(result.stopReason, "failed");
  assert.equal(result.steps[0]?.status, "failed");
  assert.match(result.steps[0]?.note ?? "", /accessibility: Not authorized https:\/\/example\.com\//);
  assert.doesNotMatch(result.steps[0]?.note ?? "", /session=abc123/);
  assert.equal(capture.run, null);
  assert.deepEqual(tools.taps, []);
});

test("live macos: completed only when Runtime completed the gated click", async () => {
  const tools = fakeLiveTools();
  const capture: RunCapture = { run: null };
  const result = await runLiveMacos(homePath, tools, capture);
  assert.equal(result.status, "completed");
  assert.equal(result.stopReason, null);
  assert.equal(result.steps[0]?.status, "ok");
  assert.equal(capture.run?.status, "completed");
  assert.equal(capture.run?.stepResults[0]?.driver, "os-macos");
  assert.equal(capture.run?.stepResults[0]?.attempt, "executed");
  assert.deepEqual(capture.run?.stepResults[0]?.target, { kind: "accessibility", name: "More information..." });
  assert.deepEqual(tools.taps, ["n1"]);
});

test("parseArgs reads intent, body, and live", () => {
  assert.equal(parseBodyKind(undefined), "macos");
  assert.deepEqual(parseArgs(["열어", "--body", "windows", "--live"]), {
    intent: "열어",
    body: "windows",
    live: true,
  });
});
