import assert from "node:assert/strict";
import { dirname, join } from "node:path";
import { test } from "node:test";
import { fileURLToPath } from "node:url";
import { LiveWindowsExecutorTools, WindowsDriverError, type LiveWindowsExecutorOptions } from "../src/index.ts";

const faultyFake = join(dirname(fileURLToPath(import.meta.url)), "fixtures", "fake-ppomi-executor-faults.mjs");
const sleep = (ms: number): Promise<void> => new Promise(done => setTimeout(done, ms));

function start(extra: Partial<LiveWindowsExecutorOptions> = {}): LiveWindowsExecutorTools {
  return LiveWindowsExecutorTools.start({
    executorPath: "unused-when-launch-is-given",
    launch: { command: process.execPath, args: [faultyFake] },
    requestTimeoutMs: 150,
    ...extra,
  });
}

function caught(block: () => unknown): { code: string | undefined; message: string } | null {
  try {
    block();
    return null;
  } catch (error) {
    return { code: error instanceof WindowsDriverError ? error.code : undefined, message: (error as Error).message };
  }
}

// Regression for the desync bug: a reply that arrives after its request timed out must not be handed
// to the next request. Before the fix the next call threw `native_unavailable: reply missing or out of
// order`, and every later call did too, so the bridge was dead until close() + a new process.
test("faults: a late reply after bridge_timeout does not break the next call", async () => {
  const tools = start();
  try {
    assert.deepEqual(tools.listApps(""), { apps: [{ label: "fakeapp", packageName: "win:4242:1", allowed: false }], truncated: false });
    assert.equal(caught(() => tools.listApps("slow"))?.code, "bridge_timeout");
    await sleep(500); // let the slow reply arrive and sit in the port ahead of the next reply
    assert.deepEqual(tools.listApps(""), { apps: [{ label: "fakeapp", packageName: "win:4242:1", allowed: false }], truncated: false });
    assert.deepEqual(tools.listApps(""), { apps: [{ label: "fakeapp", packageName: "win:4242:1", allowed: false }], truncated: false });
  } finally {
    tools.close();
  }
});

// A wedged executor (alive but no longer reading stdin, so it never exits on EOF) must not leak, and
// writing into its broken pipe must surface as an error rather than an unhandled EPIPE that crashes.
test("faults: close() reaps a wedged executor and a broken write surfaces as an error", async () => {
  const tools = start();
  const pid = tools.executorPid;
  assert.equal(typeof pid, "number");
  tools.listApps("wedge"); // replies once, then stops reading stdin and stays alive
  const blocked = caught(() => tools.listApps(""));
  assert.ok(blocked !== null && blocked.code !== undefined, `expected a WindowsDriverError, got ${JSON.stringify(blocked)}`);
  tools.close(); // closes stdin, then force-kills because EOF is never observed
  await sleep(200);
  assert.throws(() => process.kill(pid!, 0), /ESRCH/); // the executor process is gone, not leaked
});
