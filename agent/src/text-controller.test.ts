import { test } from "node:test";
import assert from "node:assert/strict";
import { RunContext } from "@openai/agents";
import { RealtimeAgent, type RealtimeItem, type RealtimeSession } from "@openai/agents/realtime";
import { NativeBridge, type Bootstrap } from "./bridge";
import { TextController, createTextSession, chatMessagesFromHistory, callMessagesFromHistory, createAgentTools, type ChatMessage, type TextState, type ToolProgress } from "./voice";

const bootstrap: Bootstrap = {
  platform: "android", deviceLabel: "fixture", configured: true,
  endpoint: "https://example.invalid", tools: ["app_list", "app_open"],
};
const tick = () => new Promise<void>(resolve => setImmediate(resolve));
const user: RealtimeItem = {
  itemId: "user", type: "message", role: "user", status: "completed",
  content: [{ type: "input_text", text: "합성 앱을 열어 주세요" }],
};
const assistant: RealtimeItem = {
  itemId: "assistant", type: "message", role: "assistant", status: "in_progress",
  content: [{ type: "output_text", text: "앱을 확인할게요." }],
};

test("text session configuration explicitly uses WebSocket with text output and no VAD or transcription", async () => {
  const session = createTextSession(new RealtimeAgent({ name: "fixture" }), "synthetic-model");
  const config = await session.getInitialSessionConfig();
  assert.ok("outputModalities" in config && "audio" in config);
  assert.equal(session.options.transport, "websocket");
  assert.deepEqual(config.outputModalities, ["text"]);
  assert.equal(config.audio?.input?.transcription, null);
  assert.equal(config.audio?.input?.turnDetection, null);
  assert.equal(config.tracing, null);
  assert.equal(session.options.historyStoreAudio, false);
  session.close();
});

test("chat projection excludes system instructions, tool payloads and audio transcripts", () => {
  const history: RealtimeItem[] = [user, assistant,
    { itemId: "system", type: "message", role: "system", content: [{ type: "input_text", text: "private instructions" }] },
    { itemId: "tool", type: "function_call", name: "file_read", arguments: "private path", output: "private file", status: "completed" },
    { itemId: "audio", type: "message", role: "assistant", status: "completed", content: [{ type: "output_audio", transcript: "private audio", audio: "private bytes" }] },
    { itemId: "said", type: "message", role: "user", status: "completed", content: [{ type: "input_audio", transcript: "private said", audio: null }] },
  ];
  assert.deepEqual(chatMessagesFromHistory(history), [
    { id: "user", role: "user", text: "합성 앱을 열어 주세요", status: "completed" },
    { id: "assistant", role: "assistant", text: "앱을 확인할게요.", status: "in_progress" },
  ]);
});

test("call projection keeps what was said as transcripts; system instructions and tool payloads still stay out", () => {
  const history: RealtimeItem[] = [user, assistant,
    { itemId: "system", type: "message", role: "system", content: [{ type: "input_text", text: "private instructions" }] },
    { itemId: "tool", type: "function_call", name: "file_read", arguments: "private path", output: "private file", status: "completed" },
    { itemId: "said", type: "message", role: "user", status: "completed", content: [{ type: "input_audio", transcript: "카드값 얼마야", audio: null }] },
    { itemId: "audio", type: "message", role: "assistant", status: "completed", content: [{ type: "output_audio", transcript: "62,000원입니다.", audio: "private bytes" }] },
  ];
  assert.deepEqual(callMessagesFromHistory(history), [
    { id: "user", role: "user", text: "합성 앱을 열어 주세요", status: "completed" },
    { id: "assistant", role: "assistant", text: "앱을 확인할게요.", status: "in_progress" },
    { id: "said", role: "user", text: "카드값 얼마야", status: "completed" },
    { id: "audio", role: "assistant", text: "62,000원입니다.", status: "completed" },
  ]);
});

test("text activation never accesses media APIs; send serializes turns and stop clears UI and SDK history", async () => {
  const original = Object.getOwnPropertyDescriptor(globalThis, "navigator");
  Object.defineProperty(globalThis, "navigator", { configurable: true, get() { assert.fail("text must not access microphone APIs"); } });
  const calls: { method: string; args: Record<string, unknown> }[] = [];
  const credential = { clientSecret: "ek_synthetic_fixture", model: "synthetic-model" };
  const bridge = new NativeBridge(raw => {
    const message = JSON.parse(raw); calls.push({ method: message.method, args: message.args });
    queueMicrotask(() => bridge.receive({ id: message.id, result: message.method === "bootstrap" ? bootstrap
      : message.method === "request" ? credential : { active: message.args.active, mode: "text" } }));
  });
  let session!: RealtimeSession;
  const states: TextState[] = [], updates: ChatMessage[][] = [], sent: unknown[] = [];
  const controller = new TextController(bridge, s => states.push(s), () => assert.fail("no error"),
    value => updates.push(value), () => {}, (agent, model) => {
      session = createTextSession(agent, model);
      session.connect = async ({ apiKey }) => { assert.equal(apiKey, "ek_synthetic_fixture"); };
      session.sendMessage = text => { sent.push(text); };
      session.mute = () => assert.fail("WebSocket must never be muted");
      return session;
    });
  try {
    await controller.start({ ...bootstrap, configured: false });
    assert.equal(states.at(-1), "ready");
    assert.deepEqual(calls.slice(0, 3), [
      { method: "bootstrap", args: {} },
      { method: "sessionState", args: { active: true, mode: "text" } },
      { method: "request", args: { path: "/v1/session", body: { mode: "text" } } },
    ]);
    assert.equal(credential.clientSecret, "");
    assert.equal(controller.send("   "), false);
    assert.equal(controller.send("x".repeat(12_001)), false);
    assert.equal(controller.send("합성 앱을 열어 주세요"), true);
    assert.equal(controller.send("중복 요청"), false);
    assert.deepEqual(sent, ["합성 앱을 열어 주세요"]);
    session.history.push(user, assistant);
    session.context.context.history = [...session.history];
    session.emit("history_updated", session.history);
    assert.equal(updates.at(-1)?.length, 2);
    session.transport.emit("turn_done", {
      type: "response_done", response: { id: "tool-turn", output: [{ type: "function_call", id: "call", name: "app_list", callId: "call", arguments: "{}" }], usage: { inputTokens: 0, outputTokens: 0, totalTokens: 0 } },
    });
    assert.equal(controller.send("도구 실행 중 중복 요청"), false);
    session.transport.emit("turn_done", {
      type: "response_done", response: { id: "final-turn", output: [], usage: { inputTokens: 0, outputTokens: 0, totalTokens: 0 } },
    });
    assert.equal(states.at(-1), "ready");
    const firstStop = controller.stop();
    const secondStop = controller.stop();
    assert.equal(firstStop, secondStop);
    assert.equal(states.at(-1), "idle");
    assert.deepEqual(updates.at(-1), []);
    await firstStop;
    assert.equal(session.history.length, 0);
    assert.equal(session.context.context.history.length, 0);
    const updateCount = updates.length;
    session.emit("history_updated", [assistant]);
    session.emit("agent_start", session.context, session.currentAgent);
    assert.equal(updates.length, updateCount);
    assert.equal(states.at(-1), "idle");
    assert.equal(calls.filter(c => c.method === "sessionState" && c.args.active === false).length, 1);
    assert.equal(bridge.pendingCount, 0);
  } finally {
    await controller.stop();
    if (original) Object.defineProperty(globalThis, "navigator", original);
    else Reflect.deleteProperty(globalThis, "navigator");
  }
});

test("stop during credential lookup drops late tokens and cannot create a new text session", async () => {
  let credentialId = "", sessions = 0;
  const calls: string[] = [];
  const bridge = new NativeBridge(raw => {
    const message = JSON.parse(raw); calls.push(message.method);
    if (message.method === "request") credentialId = message.id;
    else queueMicrotask(() => bridge.receive({ id: message.id, result: message.method === "bootstrap" ? bootstrap : { active: message.args.active } }));
  });
  const states: TextState[] = [];
  const controller = new TextController(bridge, s => states.push(s), () => assert.fail("cancellation is silent"), () => {}, () => {}, (agent, model) => {
    sessions++; return createTextSession(agent, model);
  });
  const starting = controller.start(bootstrap);
  await tick();
  assert.ok(credentialId);
  await controller.stop();
  bridge.receive({ id: credentialId, result: { clientSecret: "ek_late_fixture", model: "synthetic-model" } });
  await starting;
  assert.equal(sessions, 0);
  assert.equal(states.at(-1), "idle");
  assert.deepEqual(calls, ["bootstrap", "sessionState", "request", "sessionState"]);
  assert.equal(bridge.pendingCount, 0);
});

test("old connect completion cannot revive its session or overwrite a later text session", async () => {
  let finishOld!: () => void, count = 0;
  const bridge = new NativeBridge(raw => {
    const message = JSON.parse(raw);
    queueMicrotask(() => bridge.receive({ id: message.id, result: message.method === "bootstrap" ? bootstrap : message.method === "request"
      ? { clientSecret: "ek_fixture", model: "synthetic-model" } : { active: message.args.active } }));
  });
  const states: TextState[] = [], updates: ChatMessage[][] = [];
  const sessions: RealtimeSession[] = [];
  const controller = new TextController(bridge, s => states.push(s), () => assert.fail("cancellation is silent"), v => updates.push(v), () => {}, (agent, model) => {
    const session = createTextSession(agent, model); sessions.push(session);
    session.connect = count++ === 0 ? () => new Promise<void>(resolve => { finishOld = resolve; }) : async () => {};
    return session;
  });
  const oldStart = controller.start(bootstrap);
  await tick();
  await controller.stop();
  await controller.start(bootstrap);
  assert.equal(states.at(-1), "ready");
  finishOld();
  await oldStart;
  assert.equal(states.at(-1), "ready");
  const updateCount = updates.length;
  sessions[0].emit("history_updated", [assistant]);
  assert.equal(updates.length, updateCount);
  await controller.stop();
});

test("a second stop cancels a start waiting for the previous native stop acknowledgement", async () => {
  let stopId = "", starts = 0;
  const bridge = new NativeBridge(raw => {
    const message = JSON.parse(raw);
    if (message.method === "sessionState" && message.args.active === false) { stopId = message.id; return; }
    queueMicrotask(() => bridge.receive({ id: message.id, result: message.method === "bootstrap" ? bootstrap : message.method === "request"
      ? { clientSecret: "ek_fixture", model: "synthetic-model" } : { active: true } }));
  });
  const controller = new TextController(bridge, () => {}, () => assert.fail(), () => {}, () => {}, (agent, model) => {
    starts++;
    const session = createTextSession(agent, model);
    session.connect = async () => {};
    return session;
  });
  await controller.start(bootstrap);
  const stopping = controller.stop();
  assert.equal(controller.whenStopped(), stopping);
  const waitingStart = controller.start(bootstrap);
  assert.equal(controller.stop(), stopping);
  bridge.receive({ id: stopId, result: { active: false } });
  await Promise.all([stopping, waitingStart]);
  assert.equal(starts, 1, "cancelled waiting start must not create a second session");
  assert.equal(bridge.pendingCount, 0);
});

test("failed model responses clear chat without exposing provider failure details", async () => {
  const bridge = new NativeBridge(raw => {
    const message = JSON.parse(raw);
    queueMicrotask(() => bridge.receive({ id: message.id, result: message.method === "bootstrap" ? bootstrap : message.method === "request"
      ? { clientSecret: "ek_fixture", model: "synthetic-model" } : { active: message.args.active } }));
  });
  let session!: RealtimeSession;
  const errors: string[] = [], states: TextState[] = [], updates: ChatMessage[][] = [];
  const controller = new TextController(bridge, s => states.push(s), text => errors.push(text), v => updates.push(v), () => {}, (agent, model) => {
    session = createTextSession(agent, model); session.connect = async () => {}; return session;
  });
  await controller.start(bootstrap);
  session.emit("history_updated", [user, assistant]);
  session.emit("transport_event", { type: "response.done", response: { status: "failed", status_details: { error: { message: "private provider details" } } } });
  assert.equal(states.at(-1), "idle");
  assert.deepEqual(updates.at(-1), []);
  assert.equal(errors.length, 1);
  assert.ok(!errors[0].includes("private"));
  await controller.whenStopped();
  assert.equal(bridge.pendingCount, 0);
});

test("shared tools emit correlated safe progress without exposing inputs or native error text", async () => {
  const progress: ToolProgress[] = [];
  const bridge = new NativeBridge(raw => {
    const message = JSON.parse(raw);
    queueMicrotask(() => bridge.receive(message.args.name === "app_open"
      ? { id: message.id, error: { code: "app_not_allowed", message: "private native diagnostic" } }
      : { id: message.id, result: { apps: [{ label: "private fixture label" }] } }));
  });
  const tools = createAgentTools(bootstrap, bridge, () => {}, () => {}, event => progress.push(event));
  const open = tools.find(t => t.name === "app_open")!, list = tools.find(t => t.name === "app_list")!;
  const result = String(await open.invoke(new RunContext({}), JSON.stringify({ target: "private requested app" })));
  assert.equal(JSON.parse(result).error.code, "app_not_allowed");
  await list.invoke(new RunContext({}), JSON.stringify({ query: "private query" }));
  assert.deepEqual(progress.map(({ name, status, code }) => ({ name, status, code })), [
    { name: "app_open", status: "running", code: undefined },
    { name: "app_open", status: "error", code: "app_not_allowed" },
    { name: "app_list", status: "running", code: undefined },
    { name: "app_list", status: "success", code: undefined },
  ]);
  assert.equal(progress[0].id, progress[1].id);
  assert.equal(progress[2].id, progress[3].id);
  assert.notEqual(progress[0].id, progress[2].id);
  assert.ok(!JSON.stringify(progress).includes("private"));
});
