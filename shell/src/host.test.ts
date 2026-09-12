import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { test } from "node:test";
import { parseArgs, parseBodyKind, runSpine } from "./host.ts";

const hostFile = join(dirname(fileURLToPath(import.meta.url)), "host.ts");

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

test("host CLI exits 0 and prints JSON when no path matches", () => {
  const result = spawnSync(process.execPath, ["--experimental-strip-types", hostFile, "--intent", "no-such-path"], {
    encoding: "utf8",
    cwd: join(dirname(hostFile), ".."),
  });
  assert.equal(result.status, 0, result.stderr);
  const body = JSON.parse(result.stdout) as { status: string };
  assert.equal(body.status, "path_not_found");
});

test("windows and android fixtures share the same spine IPC", async () => {
  const windows = await runSpine({ intent: "browse", body: "windows", live: false });
  const android = await runSpine({ intent: "home", body: "android", live: false });
  assert.equal(windows.status, "completed");
  assert.equal(android.status, "completed");
  assert.equal(windows.bodyKind, "windows");
  assert.equal(android.bodyKind, "android");
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
