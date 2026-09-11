import assert from "node:assert/strict";
import { test } from "node:test";
import { probeAndroidLive } from "../example/src/live-probe.ts";

test("android live probe is dry-run unless PPOMI_BODY_LIVE=1", () => {
  const previous = process.env.PPOMI_BODY_LIVE;
  delete process.env.PPOMI_BODY_LIVE;
  try {
    const probe = probeAndroidLive();
    assert.equal(probe.status, "ok");
    assert.ok(probe.lines.some(line => line.includes("dry-run")));
  } finally {
    if (previous === undefined) delete process.env.PPOMI_BODY_LIVE;
    else process.env.PPOMI_BODY_LIVE = previous;
  }
});
