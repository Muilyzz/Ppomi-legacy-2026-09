import assert from "node:assert/strict";
import { test } from "node:test";
import { probeIphoneMirroringLive } from "../example/src/live-probe.ts";

test("iphone mirroring live probe skips off macOS", () => {
  if (process.platform === "darwin") return;
  const probe = probeIphoneMirroringLive();
  assert.equal(probe.status, "skip");
  assert.ok(probe.lines.some(line => line.includes("not macOS")));
});
