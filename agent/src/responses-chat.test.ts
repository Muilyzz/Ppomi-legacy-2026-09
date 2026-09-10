import { test } from "node:test";
import assert from "node:assert/strict";
import { NativeBridge, type Bootstrap } from "./bridge";
import { TextController, type ChatMessage, type TextState } from "./voice";
import { chatMessagesFromItems } from "./responses-chat";

const mac: Bootstrap = {
  platform: "macos", deviceLabel: "Mac", configured: true, endpoint: "https://example.invalid",
  tools: ["device_status", "phone_screen"], responsesTransport: true,
  toolSpecs: [{ name: "phone_screen", description: "iPhone 화면", parameters: { type: "object", required: [], properties: {} } }],
};
const response = (output: unknown[]) => ({ id: "resp_" + Math.random().toString(36).slice(2), object: "response", created_at: 1, status: "completed", model: "gpt-6-astra",
  output, usage: { input_tokens: 1, output_tokens: 1, total_tokens: 2, input_tokens_details: { cached_tokens: 0 }, output_tokens_details: { reasoning_tokens: 0 } } });

test("text chat on the flagship model: session says responses, turns go through the proxy, tools run natively, only text becomes rows", async () => {
  const requests: Record<string, unknown>[] = [], states: TextState[] = [];
  let rows: ChatMessage[] = [], turn = 0;
  const bridge = new NativeBridge(raw => {
    const request = JSON.parse(raw) as { id: string; method: string; args: Record<string, unknown> };
    const reply = (result: unknown) => queueMicrotask(() => bridge.receive({ id: request.id, result }));
    if (request.method === "bootstrap") return reply(mac);
    if (request.method === "sessionState") return reply({});
    if (request.method === "executeTool") return reply({ text: "0.10  홈 화면", error: false });
    const args = request.args as { path: string; body: Record<string, unknown> };
    if (args.path === "/v1/session") { requests.push(args.body); return reply({ transport: "responses", model: "gpt-6-astra" }); }
    if (args.path === "/v1/responses") {
      requests.push(args.body);
      return reply(++turn === 1
        ? response([{ type: "function_call", id: "fc_1", call_id: "call_1", name: "phone_screen", arguments: "{}", status: "completed" }])
        : response([{ type: "message", id: "msg_1", role: "assistant", status: "completed", content: [{ type: "output_text", text: "홈 화면입니다.", annotations: [] }] }]));
    }
    throw new Error("unexpected " + request.method);
  });
  const controller = new TextController(bridge, state => states.push(state), text => { throw new Error(text); }, m => { rows = m; }, () => {});
  await controller.start(mac);
  assert.deepEqual(requests[0], { mode: "text", responses: true });
  assert.equal(states.at(-1), "ready");
  assert.equal(controller.send("아이폰 화면 읽어"), true);
  for (let i = 0; i < 200 && states.at(-1) !== "ready"; i++) await new Promise(r => setTimeout(r, 10));
  assert.equal(states.at(-1), "ready");
  assert.ok(states.includes("working"), states.join(","));
  const first = requests[1] as { input: unknown[]; tools: { name: string }[]; instructions?: string; model?: string };
  assert.ok(first.tools.some(tool => tool.name === "phone_screen"));
  assert.match(String(first.instructions), /phone_screen/);
  const second = requests[2] as { input: { type?: string; call_id?: string; output?: unknown }[] };
  assert.ok(second.input.some(item => item.type === "function_call_output" && item.call_id === "call_1" && String(item.output).includes("홈 화면")));
  assert.deepEqual(rows.map(row => [row.role, row.text]), [["user", "아이폰 화면 읽어"], ["assistant", "홈 화면입니다."]]);
  await controller.stop();
  assert.equal(states.at(-1), "idle");
});

test("chat rows come only from user and assistant message items", () => {
  const rows = chatMessagesFromItems([
    { role: "user", content: "안녕" },
    { type: "function_call", id: "fc", callId: "c", name: "phone_screen", arguments: "{}", status: "completed" } as never,
    { type: "message", role: "assistant", id: "m1", status: "completed", content: [{ type: "output_text", text: "네" }] } as never,
  ]);
  assert.deepEqual(rows.map(row => [row.role, row.text, row.status]), [["user", "안녕", "completed"], ["assistant", "네", "completed"]]);
});
