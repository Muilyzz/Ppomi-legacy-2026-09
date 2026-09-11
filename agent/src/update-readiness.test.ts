import test from "node:test";
import assert from "node:assert/strict";
import { validateBootstrap, UpdateCompatibilityError, type Bootstrap } from "./bridge";
import { BootstrapReadiness } from "./update-readiness";

const legacy: Bootstrap = { platform: "macos", deviceLabel: "Test", configured: true, endpoint: "https://example.org", tools: [] };
const modern: Bootstrap = { ...legacy, nativeBuild: 1, bridgeVersion: 1, webRelease: "family-1", capabilities: ["agent.v1", "records.v1"] };
function deferred() {
  let resolve!: () => void, reject!: (error: Error) => void;
  const promise = new Promise<void>((yes, no) => { resolve = yes; reject = no; });
  return { promise, resolve, reject };
}
test("old native hosts remain compatible without update metadata", () => {
  assert.deepEqual(validateBootstrap(legacy), legacy);
});
test("text and OS-answered calls remain blocked through render and until native acknowledgement", async () => {
  const ack = deferred(); let acknowledgements = 0; const sessions: string[] = [];
  const gate = new BootstrapReadiness(() => { acknowledgements++; return ack.promise; });
  const text = gate.wait().then(() => { sessions.push("text"); });
  const answeredCall = gate.wait().then(() => { sessions.push("answered-call"); });
  gate.prepare(modern);
  await Promise.resolve();
  assert.equal(acknowledgements, 0); assert.deepEqual(sessions, []);
  const mounted = gate.commit();
  assert.equal(gate.commit(), mounted); assert.equal(acknowledgements, 1);
  await Promise.resolve(); assert.deepEqual(sessions, []);
  ack.resolve(); await mounted; await Promise.all([text, answeredCall]);
  assert.deepEqual(sessions, ["text", "answered-call"]);
});
test("older hosts pass the committed barrier without calling an unsupported method", async () => {
  const gate = new BootstrapReadiness(async () => { assert.fail("legacy host must not receive updateReady"); });
  gate.prepare(legacy); await gate.commit();
  assert.deepEqual(await gate.wait(), legacy);
});
test("Tauri executors keep their real OS identity without opting into family update acknowledgement", async () => {
  for (const platform of ["macos", "windows", "android"] as const) {
    const gate = new BootstrapReadiness(async () => { assert.fail("Tauri executors do not implement updateReady"); });
    const boot = { ...legacy, platform, executor: { nativeAutomation: true }, authentication: { signedIn: false } };
    gate.prepare(boot); await gate.commit();
    assert.equal((await gate.wait()).platform, platform);
    const refreshed = { ...boot, configured: false, executor: { nativeAutomation: false } };
    gate.prepare(refreshed);
    assert.deepEqual(await gate.wait(), refreshed);
  }
});
test("Windows cannot bypass the family compatibility barrier by supplying partial update metadata", () => {
  assert.throws(() => validateBootstrap({ ...legacy, platform: "windows", bridgeVersion: 1 }), UpdateCompatibilityError);
  assert.deepEqual(validateBootstrap({ ...modern, platform: "windows" }), { ...modern, platform: "windows" });
});
test("failed native acknowledgement rejects pending actions and cannot be revived by another bootstrap", async () => {
  const ack = deferred(); let sessionStarted = false;
  const gate = new BootstrapReadiness(() => ack.promise);
  gate.prepare(modern);
  const pending = gate.wait().then(() => { sessionStarted = true; });
  const mounted = gate.commit();
  const pendingRejected = assert.rejects(pending, /다시 열어/), commitRejected = assert.rejects(mounted, /다시 열어/);
  ack.reject(new Error("native startup failed"));
  await Promise.all([pendingRejected, commitRejected]);
  assert.equal(sessionStarted, false); assert.equal(gate.failed, true);
  assert.throws(() => gate.prepare(modern), /다시 열어/);
  await assert.rejects(gate.wait(), /다시 열어/);
});
test("an incompatible refresh arriving before acknowledgement permanently closes the barrier", async () => {
  const ack = deferred(), gate = new BootstrapReadiness(() => ack.promise);
  gate.prepare(modern); const mounted = gate.commit();
  const pending = assert.rejects(gate.wait(), UpdateCompatibilityError);
  assert.throws(() => gate.prepare({ ...modern, bridgeVersion: 2 }), UpdateCompatibilityError);
  ack.resolve(); await assert.rejects(mounted, UpdateCompatibilityError); await pending;
});
test("compatible refreshes supply latest tools while native identity changes cannot reuse a resolved barrier", async () => {
  let acknowledgements = 0;
  const gate = new BootstrapReadiness(async () => { acknowledgements++; });
  gate.prepare(modern); await gate.commit();
  const refreshed = { ...modern, capabilities: ["records.v1", "agent.v1"], tools: ["screen_read"] };
  gate.prepare(refreshed); await gate.commit();
  assert.deepEqual(await gate.wait(), refreshed); assert.equal(acknowledgements, 1);
  assert.throws(() => gate.prepare({ ...modern, webRelease: "different" }), UpdateCompatibilityError);
  await assert.rejects(gate.wait(), UpdateCompatibilityError);
});
test("valid native metadata enables the agent capability", () => {
  const boot = { ...legacy, nativeBuild: 1, bridgeVersion: 1, webRelease: "family-1", capabilities: ["agent.v1", "records.v1"] };
  assert.deepEqual(validateBootstrap(boot), boot);
});
test("incompatible or partial bootstrap never reaches a session controller", () => {
  for (const bad of [null, {}, { ...legacy, nativeBuild: 1 }, { ...legacy, platform: "ipados" },
    { ...legacy, nativeBuild: 1, bridgeVersion: 2, webRelease: "test", capabilities: ["agent.v1"] },
    { ...legacy, nativeBuild: 1, bridgeVersion: 1, webRelease: "test", capabilities: ["records.v1"] },
    { ...legacy, nativeBuild: 1, bridgeVersion: 1, webRelease: "test", capabilities: ["agent.v1", "agent.v1"] }]) {
    assert.throws(() => validateBootstrap(bad), UpdateCompatibilityError);
  }
});
