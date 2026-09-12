import assert from "node:assert/strict";
import { dirname, join } from "node:path";
import { test } from "node:test";
import { fileURLToPath } from "node:url";
import { parseArgs, parseBodyKind, runSpine } from "./host.ts";

const fakeExecutor = join(
  dirname(fileURLToPath(import.meta.url)),
  "..",
  "..",
  "packages",
  "ppomi-body-windows",
  "tests",
  "fixtures",
  "fake-ppomi-executor.mjs",
);

test("macos fixture 1-step reaches ppomi-body-macos through brain", async () => {
  const result = await runSpine({ intent: "다음", body: "macos", live: false });
  assert.equal(result.status, "completed");
  assert.equal(result.pathId, "path-home-next");
  assert.equal(result.bodyKind, "macos");
  assert.equal(result.body?.status, "completed");
  assert.equal(result.body?.steps[0]?.status, "ok");
  assert.match(result.hook, /PPOMI_BODY_LIVE=1/);
});

test("unknown intent never calls body", async () => {
  const result = await runSpine({ intent: "no-such-path", body: "macos", live: false });
  assert.equal(result.status, "path_not_found");
  assert.equal(result.body, null);
});

test("windows and android fixtures share the same spine IPC", async () => {
  const windows = await runSpine({ intent: "browse", body: "windows", live: false });
  const android = await runSpine({ intent: "home", body: "android", live: false });
  assert.equal(windows.status, "completed");
  assert.equal(android.status, "completed");
  assert.equal(windows.bodyKind, "windows");
  assert.equal(android.bodyKind, "android");
  assert.equal(windows.body?.status, "completed");
  assert.equal(windows.body?.steps[0]?.status, "ok");
  assert.match(windows.hook, /--body windows --live/);
});

test("live windows off-win32 skips instead of failing", async () => {
  if (process.platform === "win32") return;
  const result = await runSpine({ intent: "다음", body: "windows", live: true });
  assert.equal(result.status, "completed");
  assert.equal(result.bodyKind, "windows");
  assert.equal(result.live, true);
  assert.match(result.note, /not win32/);
});

test("live windows 1-step reaches the executor protocol through the same spine", async () => {
  const previous = process.env.PPOMI_WINDOWS_FAKE_EXECUTOR;
  process.env.PPOMI_WINDOWS_FAKE_EXECUTOR = fakeExecutor;
  try {
    const result = await runSpine({ intent: "browse", body: "windows", live: true });
    assert.equal(result.status, "completed");
    assert.equal(result.bodyKind, "windows");
    assert.equal(result.live, true);
    assert.equal(result.body?.status, "completed");
    assert.equal(result.body?.steps[0]?.status, "ok");
    assert.match(result.hook, /--body windows --live/);
  } finally {
    if (previous === undefined) delete process.env.PPOMI_WINDOWS_FAKE_EXECUTOR;
    else process.env.PPOMI_WINDOWS_FAKE_EXECUTOR = previous;
  }
});

test("live macos off-darwin skips instead of failing", async () => {
  if (process.platform === "darwin") return;
  const result = await runSpine({ intent: "다음", body: "macos", live: true });
  assert.equal(result.status, "completed");
  assert.match(result.note, /not darwin/);
});

test("parseArgs reads intent, body, and live", () => {
  assert.equal(parseBodyKind(undefined), "macos");
  assert.deepEqual(parseArgs(["열어", "--body", "windows", "--live"]), {
    intent: "열어",
    body: "windows",
    live: true,
  });
});
