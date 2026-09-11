import assert from "node:assert/strict";
import { test } from "node:test";
import { liveReporterOutcome, probeWindowsLive } from "../example/src/live-probe.ts";

test("windows live probe skips off Windows", () => {
  if (process.platform === "win32") return;
  const probe = probeWindowsLive();
  assert.equal(probe.status, "skip");
  assert.ok(probe.lines.some(line => line.includes("not Windows")));
});

test("live reporter: unicode spec lines still count as pass/skip", () => {
  assert.equal(liveReporterOutcome(0, "ℹ tests 1\nℹ pass 1\nℹ fail 0"), "ok");
  assert.equal(liveReporterOutcome(0, "# tests 1\n# pass 1\n# fail 0"), "ok");
  assert.equal(liveReporterOutcome(0, "ℹ skipped 1\n# SKIP live Windows UIA smoke runs only on Windows"), "skip");
  assert.equal(liveReporterOutcome(1, "ℹ pass 1"), "fail");
  assert.equal(liveReporterOutcome(0, "no summary"), "fail");
});
