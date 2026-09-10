import { test } from "node:test";
import assert from "node:assert/strict";
import { RealtimeAgent, RealtimeSession } from "@openai/agents/realtime";
import { NativeBridge } from "./bridge";
import { VoiceController, TextController, type TextState } from "./voice";

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

test("actual browser text controller stops without media, refuses late turns and reaches native stop", async () => {
  const bootstrap = { platform: "android" as const, deviceLabel: "synthetic", configured: true, endpoint: "https://example.invalid", tools: [] };
  const calls: unknown[] = [];
  const bridge = new NativeBridge(raw => {
    const message = JSON.parse(raw); calls.push({ method: message.method, args: message.args });
    queueMicrotask(() => bridge.receive({ id: message.id, result: message.method === "bootstrap" ? bootstrap : message.method === "request"
      ? { model: "synthetic-model" } : { active: message.args.active } }));
  });
  const states: TextState[] = [];
  let turns = 0;
  const controller = new TextController(bridge, s => states.push(s), () => assert.fail(), () => {}, () => {}, () => ({
    sendMessages: async () => { turns++; return new ReadableStream(); }, reconnectToStream: async () => null,
  }));
  await controller.start(bootstrap);
  assert.equal(states.at(-1), "ready");
  const turn = { trigger: "submit-message" as const, chatId: "c", messageId: undefined, messages: [], abortSignal: undefined };
  await controller.sendMessages(turn);
  await controller.stop();
  await assert.rejects(controller.sendMessages(turn), (error: Error) => error.message === "대화 종료");
  assert.equal(turns, 1);
  assert.deepEqual(calls.at(-1), { method: "sessionState", args: { active: false, mode: "text" } });
  assert.equal(bridge.pendingCount, 0);
});
