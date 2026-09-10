import { test } from "node:test";
import assert from "node:assert/strict";
import { VoiceLifetime } from "./lifetime";
import { NativeBridge } from "./bridge";
test("late connect response cannot revive ended session or enter its successor", () => {
  const life = new VoiceLifetime();
  const old = life.begin();
  life.end();
  const next = life.begin();
  assert.throws(() => life.assert(old));
  assert.equal(life.isCurrent(next), true);
  life.end();
  assert.throws(() => life.assert(next));
});
test("stop rejects and clears pending native payload callbacks, late reply is ignored", async () => {
  let sent = "";
  const b = new NativeBridge((m) => {
    sent = m;
  });
  const p = b.call("request", { path: "/v1/session", body: {} });
  const rejected = assert.rejects(p, /종료/);
  b.clear();
  await rejected;
  assert.equal(b.pendingCount, 0);
  b.receive({
    id: JSON.parse(sent).id,
    result: { clientSecret: "never retained" },
  });
  assert.equal(b.pendingCount, 0);
});
test("bridge resolves exactly once without exposing raw native error text", async () => {
  let id = "";
  const b = new NativeBridge((m) => {
    id = JSON.parse(m).id;
  });
  const p = b.call("bootstrap");
  b.receive({ id, error: { code: "FAIL", message: "secret transcript" } });
  await assert.rejects(
    p,
    (e) => e instanceof Error && !e.message.includes("secret"),
  );
  assert.equal(b.pendingCount, 0);
});
