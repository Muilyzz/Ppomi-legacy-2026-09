import { test } from "node:test";
import assert from "node:assert/strict";
import { RealtimeAgent, RealtimeSession } from "@openai/agents/realtime";
import { NativeBridge } from "./bridge";
import { VoiceController, TextController, createTextSession, type ChatMessage } from "./voice";

test("actual browser SDK emitter teardown reaches native stop and clears history", async () => {
  const calls: string[] = [];
  const bridge = new NativeBridge((raw) => {
    const m = JSON.parse(raw);
    calls.push(m.method + ":" + m.args.active);
    queueMicrotask(() =>
      bridge.receive({ id: m.id, result: { active: false } }),
    );
  });
  const agent = new RealtimeAgent({ name: "synthetic fixture" });
  const session = new RealtimeSession(agent, {
    transport: "websocket",
    tracingDisabled: true,
    historyStoreAudio: false,
  });
  assert.equal(
    typeof (session as unknown as { removeAllListeners?: unknown })
      .removeAllListeners,
    "undefined",
    "run with --conditions=browser to exercise the shipped emitter",
  );
  session.history.push({
    itemId: "synthetic",
    type: "message",
    role: "user",
    status: "completed",
    content: [{ type: "input_text", text: "ephemeral fixture" }],
  });
  let updates = 0;
  const listener = () => {
    updates++;
  };
  session.on("audio_start", listener);
  const voice = new VoiceController(
    bridge,
    () => {},
    () => assert.fail(),
  );
  const internals = voice as unknown as {
    session: RealtimeSession;
    unsubscribe: (() => void)[];
  };
  internals.session = session;
  internals.unsubscribe.push(() => {
    session.off("audio_start", listener);
  });
  await voice.stop();
  session.emit("audio_start", session.context, agent);
  assert.deepEqual(calls, ["sessionState:false"]);
  assert.equal(session.history.length, 0);
  assert.equal(session.context.context.history.length, 0);
  assert.equal(updates, 0);
  assert.equal(bridge.pendingCount, 0);
});

test("actual browser text controller stops without media and drops late history callbacks", async () => {
  const bootstrap = { platform: "android" as const, deviceLabel: "synthetic", configured: true, endpoint: "https://example.invalid", tools: [] };
  const calls: unknown[] = [];
  const bridge = new NativeBridge(raw => {
    const message = JSON.parse(raw); calls.push({ method: message.method, args: message.args });
    queueMicrotask(() => bridge.receive({ id: message.id, result: message.method === "bootstrap" ? bootstrap : message.method === "request"
      ? { clientSecret: "ek_fixture", model: "synthetic-model" } : { active: message.args.active } }));
  });
  let session!: RealtimeSession;
  const messages: ChatMessage[][] = [];
  const controller = new TextController(bridge, () => {}, () => assert.fail(), v => messages.push(v), () => {}, (agent, model) => {
    session = createTextSession(agent, model);
    session.connect = async () => {};
    return session;
  });
  await controller.start(bootstrap);
  assert.equal(typeof (session as unknown as { removeAllListeners?: unknown }).removeAllListeners, "undefined");
  const config = await session.getInitialSessionConfig();
  assert.ok("outputModalities" in config);
  assert.deepEqual(config.outputModalities, ["text"]);
  session.history.push({ itemId: "synthetic", type: "message", role: "user", status: "completed", content: [{ type: "input_text", text: "ephemeral fixture" }] });
  session.context.context.history = [...session.history];
  session.emit("history_updated", session.history);
  await controller.stop();
  assert.equal(session.history.length, 0);
  assert.equal(session.context.context.history.length, 0);
  assert.deepEqual(messages.at(-1), []);
  const count = messages.length;
  session.emit("history_updated", [{ itemId: "late", type: "message", role: "assistant", status: "completed", content: [{ type: "output_text", text: "late fixture" }] }]);
  assert.equal(messages.length, count);
  assert.deepEqual(calls.at(-1), { method: "sessionState", args: { active: false, mode: "text" } });
  assert.equal(bridge.pendingCount, 0);
});
