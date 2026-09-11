import assert from "node:assert/strict";
import { test } from "node:test";
import { probeWindowsLive } from "../example/src/live-probe.ts";

test("windows live probe skips off Windows", () => {
  if (process.platform === "win32") return;
  const probe = probeWindowsLive();
  assert.equal(probe.status, "skip");
  assert.ok(probe.lines.some(line => line.includes("not Windows")));
});
