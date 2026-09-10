import { test } from "node:test";
import assert from "node:assert/strict";
import { RunContext, type Tool } from "@openai/agents";
import type { RealtimeItem } from "@openai/agents/realtime";
import { NativeBridge, type Bootstrap } from "./bridge";
import { TextController, callMessagesFromHistory, createAgentTools, type TextState, type ToolProgress } from "./voice";

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
const turn = { trigger: "submit-message" as const, chatId: "chat", messageId: undefined, messages: [], abortSignal: undefined };
/** A transport factory that records the tools it was given and counts turns; no model is involved. */
function factory(record: { tools?: Tool[]; turns: number; instructions?: string }) {
  return (_bridge: NativeBridge, _check: () => void, _model: string, instructions: string, tools: Tool[]) => {
    record.tools = tools; record.instructions = instructions;
    return { sendMessages: async () => { record.turns++; return new ReadableStream(); }, reconnectToStream: async () => null };
  };
}

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

test("text activation never accesses media APIs or secrets; turns go through the transport until stop refuses them", async () => {
  const original = Object.getOwnPropertyDescriptor(globalThis, "navigator");
  Object.defineProperty(globalThis, "navigator", { configurable: true, get() { assert.fail("text must not access microphone APIs"); } });
  const calls: { method: string; args: Record<string, unknown> }[] = [];
  const bridge = new NativeBridge(raw => {
    const message = JSON.parse(raw); calls.push({ method: message.method, args: message.args });
    queueMicrotask(() => bridge.receive({ id: message.id, result: message.method === "bootstrap" ? bootstrap
      : message.method === "request" ? { model: "synthetic-model" } : { active: message.args.active, mode: "text" } }));
  });
  const record = { turns: 0 } as Parameters<typeof factory>[0];
  const states: TextState[] = [];
  const controller = new TextController(bridge, s => states.push(s), () => assert.fail("no error"), () => {}, () => {}, factory(record));
  try {
    await controller.start({ ...bootstrap, configured: false });
    assert.deepEqual(states, ["connecting", "ready"]);
    assert.deepEqual(calls.slice(0, 3), [
      { method: "bootstrap", args: {} },
      { method: "sessionState", args: { active: true, mode: "text" } },
      { method: "request", args: { path: "/v1/session", body: { mode: "text" } } },
    ]);
    assert.deepEqual(record.tools?.map(tool => tool.name), ["app_list", "app_open", "request_user_input", "list_playbooks", "read_playbook", "list_memories", "save_memory", "end_conversation"]);
    assert.match(String(record.instructions), /app_open/);
    await controller.sendMessages(turn);
    assert.equal(record.turns, 1);
    const firstStop = controller.stop();
    const secondStop = controller.stop();
    assert.equal(firstStop, secondStop);
    assert.equal(states.at(-1), "idle");
    await firstStop;
    await assert.rejects(controller.sendMessages(turn), (error: Error) => error.message === "대화 종료");
    assert.equal(record.turns, 1);
    assert.equal(calls.filter(c => c.method === "sessionState" && c.args.active === false).length, 1);
    assert.equal(bridge.pendingCount, 0);
  } finally {
    await controller.stop();
    if (original) Object.defineProperty(globalThis, "navigator", original);
    else Reflect.deleteProperty(globalThis, "navigator");
  }
});

test("a session without a model name fails to start with a safe reason", async () => {
  const bridge = new NativeBridge(raw => {
    const message = JSON.parse(raw);
    queueMicrotask(() => bridge.receive({ id: message.id, result: message.method === "bootstrap" ? bootstrap : message.method === "request" ? {} : { active: message.args.active } }));
  });
  const errors: string[] = [], states: TextState[] = [];
  const controller = new TextController(bridge, s => states.push(s), text => errors.push(text), () => {}, () => {}, factory({ turns: 0 }));
  await controller.start(bootstrap);
  assert.deepEqual(errors, ["처리 실패"]);
  assert.equal(states.at(-1), "idle");
  await controller.whenStopped();
  assert.equal(bridge.pendingCount, 0);
});

test("stop during the session request drops the late reply and cannot create a transport", async () => {
  let requestId = "";
  const calls: string[] = [];
  const bridge = new NativeBridge(raw => {
    const message = JSON.parse(raw); calls.push(message.method);
    if (message.method === "request") requestId = message.id;
    else queueMicrotask(() => bridge.receive({ id: message.id, result: message.method === "bootstrap" ? bootstrap : { active: message.args.active } }));
  });
  const record = { turns: 0, transports: 0 };
  const states: TextState[] = [];
  const controller = new TextController(bridge, s => states.push(s), () => assert.fail("cancellation is silent"), () => {}, () => {}, (...args) => {
    record.transports++; return factory(record)(...args);
  });
  const starting = controller.start(bootstrap);
  await tick();
  assert.ok(requestId);
  await controller.stop();
  bridge.receive({ id: requestId, result: { model: "synthetic-model" } });
  await starting;
  assert.equal(record.transports, 0);
  assert.equal(states.at(-1), "idle");
  assert.deepEqual(calls, ["bootstrap", "sessionState", "request", "sessionState"]);
  assert.equal(bridge.pendingCount, 0);
});

test("a second stop cancels a start waiting for the previous native stop acknowledgement", async () => {
  let stopId = "";
  const bridge = new NativeBridge(raw => {
    const message = JSON.parse(raw);
    if (message.method === "sessionState" && message.args.active === false) { stopId = message.id; return; }
    queueMicrotask(() => bridge.receive({ id: message.id, result: message.method === "bootstrap" ? bootstrap : message.method === "request"
      ? { model: "synthetic-model" } : { active: true } }));
  });
  let starts = 0;
  const controller = new TextController(bridge, () => {}, () => assert.fail(), () => {}, () => {}, (...args) => { starts++; return factory({ turns: 0 })(...args); });
  await controller.start(bootstrap);
  const stopping = controller.stop();
  assert.equal(controller.whenStopped(), stopping);
  const waitingStart = controller.start(bootstrap);
  assert.equal(controller.stop(), stopping);
  bridge.receive({ id: stopId, result: { active: false } });
  await Promise.all([stopping, waitingStart]);
  assert.equal(starts, 1, "cancelled waiting start must not create a second transport");
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
