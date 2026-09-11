import assert from "node:assert/strict";
import { dirname, join } from "node:path";
import { test } from "node:test";
import { fileURLToPath } from "node:url";
import {
  liveProbePlaybook,
  probeWindowsLive,
  type LiveProbePage,
  type LiveSession,
} from "../example/src/live-probe.ts";
import { LiveWindowsExecutorTools } from "../src/index.ts";

const fake = join(dirname(fileURLToPath(import.meta.url)), "fixtures", "fake-ppomi-executor.mjs");

/** The fake executor's window: an editable `Name`, a `Go` button, and `idle` → `tapped` after the tap. */
const fakePage: LiveProbePage = { inputLabel: "Name", buttonLabel: "Go", markBefore: "idle", markAfter: "tapped" };

function fakeSession(): Promise<LiveSession> {
  const tools = LiveWindowsExecutorTools.start({
    executorPath: "unused-when-launch-is-given",
    launch: { command: process.execPath, args: [fake] },
  });
  return Promise.resolve({
    tools,
    appLabel: "fakeapp",
    async close() {
      tools.close();
    },
  });
}

test("windows live probe skips off Windows", async () => {
  if (process.platform === "win32") return;
  const probe = await probeWindowsLive();
  assert.equal(probe.status, "skip");
  assert.ok(probe.lines.some(line => line.includes("not Windows")));
});

test("windows live probe dry-runs without PPOMI_BODY_LIVE and never opens a session", async () => {
  let sessions = 0;
  const probe = await probeWindowsLive({
    platform: "win32",
    live: false,
    session: () => {
      sessions += 1;
      return fakeSession();
    },
  });
  assert.equal(probe.status, "ok");
  assert.ok(probe.lines.some(line => line.includes("dry-run")));
  assert.equal(sessions, 0);
});

test("the live playbook declares an effect on every mutation and reads the screen before acting", () => {
  const playbook = liveProbePlaybook(fakePage, 10);
  assert.deepEqual(playbook.steps.map(step => [step.kind, step.effect]), [["type", "input"], ["click", "navigate"], ["read", undefined]]);
  assert.deepEqual(playbook.steps[0]?.require?.screen, ["Go", "idle"]);
  assert.deepEqual(playbook.steps[2]?.require?.screen, ["tapped"]);
});

test("live branch drives the executor only through Runtime + OsSurface(WindowsDriver) and reports the structured result", async () => {
  const probe = await probeWindowsLive({
    platform: "win32",
    live: true,
    page: fakePage,
    session: fakeSession,
    waitMs: 200,
    pollIntervalMs: 10,
  });
  assert.equal(probe.status, "ok", probe.lines.join("\n"));
  assert.ok(probe.lines.includes("runtime   completed"), probe.lines.join("\n"));
  const steps = probe.lines.filter(line => line.startsWith("step"));
  assert.equal(steps.length, 3);
  for (const [index, id] of ["type-box", "tap-button", "confirm-tap"].entries()) {
    assert.match(steps[index] ?? "", new RegExp(`^step\\s+${id}\\s+ok\\s+executed\\s+-\\s+os-windows$`), steps[index]);
  }
  const text = probe.lines.join("\n");
  assert.doesNotMatch(text, /ppomi live probe/);
  assert.doesNotMatch(text, /bounds|left|top|\bx=|\by=|nodeId|fake\d+:\d+/);
});

test("live branch reports a stopped run structurally instead of throwing", async () => {
  const probe = await probeWindowsLive({
    platform: "win32",
    live: true,
    page: { ...fakePage, markAfter: "never shown" },
    session: fakeSession,
    waitMs: 50,
    pollIntervalMs: 10,
  });
  assert.equal(probe.status, "fail");
  assert.ok(probe.lines.includes("runtime   stopped (precondition_failed)"), probe.lines.join("\n"));
  const confirm = probe.lines.find(line => line.startsWith("step      confirm-tap"));
  assert.match(confirm ?? "", /retryable\s+timeout\s+screen_missing\s+os-windows$/, confirm);
});
