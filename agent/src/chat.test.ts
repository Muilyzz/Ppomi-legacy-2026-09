import { test } from "node:test";
import assert from "node:assert/strict";
import type { UIMessageChunk } from "ai";
import { NativeBridge, type Bootstrap } from "./bridge";
import { createChatTransport } from "./chat";
import { createAgentTools, voiceInstructions, type ToolProgress } from "./voice";

const mac: Bootstrap = {
  platform: "macos", deviceLabel: "Mac", configured: true, endpoint: "https://example.invalid",
  tools: ["device_status", "phone_screen", "path_cold_start"],
  toolSpecs: [
    { name: "phone_screen", description: "iPhone 화면", parameters: { type: "object", required: [], properties: {} } },
    { name: "path_cold_start", description: "채팅에서 KB스타기업뱅킹·사업자 계좌 요청이 오면 바로 호출한다", parameters: { type: "object", required: [], properties: { app: { type: "string" } } } },
  ],
  toolGuide: "KB 사업자 계좌·KB스타기업뱅킹을 열라는 말은 Home → KB 버튼을 누르라고 하지 말고 바로 path_cold_start(app: kb-enterprise)를 호출한다.",
};
const response = (output: unknown[]) => ({ id: "resp_" + Math.random().toString(36).slice(2), object: "response", created_at: 1, status: "completed", model: "gpt-6-astra",
  output, usage: { input_tokens: 1, output_tokens: 1, total_tokens: 2, input_tokens_details: { cached_tokens: 0 }, output_tokens_details: { reasoning_tokens: 0 } } });
async function chunks(stream: ReadableStream<UIMessageChunk>) {
  const out: UIMessageChunk[] = [];
  for await (const chunk of stream as unknown as AsyncIterable<UIMessageChunk>) out.push(chunk);
  return out;
}
const turn = (text: string) => ({ trigger: "submit-message" as const, chatId: "chat", messageId: undefined, abortSignal: undefined,
  messages: [{ id: "u1", role: "user" as const, parts: [{ type: "text" as const, text }] }] });

test("a chat turn: the model is proxied through the bridge, tools run natively, the UI stream carries tool steps and text", async () => {
  const requests: Record<string, unknown>[] = [], progress: ToolProgress[] = [];
  let turnCount = 0;
  const bridge = new NativeBridge(raw => {
    const request = JSON.parse(raw) as { id: string; method: string; args: Record<string, unknown> };
    const reply = (result: unknown) => queueMicrotask(() => bridge.receive({ id: request.id, result }));
    if (request.method === "executeTool") return reply({ text: "0.10  홈 화면", error: false });
    const args = request.args as { path: string; body: Record<string, unknown> };
    if (args.path === "/v1/responses") {
      requests.push(args.body);
      return reply(++turnCount === 1
        ? response([{ type: "function_call", id: "fc_1", call_id: "call_1", name: "phone_screen", arguments: "{}", status: "completed" }])
        : response([{ type: "message", id: "msg_1", role: "assistant", status: "completed", content: [{ type: "output_text", text: "홈 화면입니다.", annotations: [] }] }]));
    }
    throw new Error("unexpected " + request.method);
  });
  const tools = createAgentTools(mac, bridge, () => {}, () => {}, event => progress.push(event));
  const transport = createChatTransport(bridge, () => {}, "gpt-6-astra", voiceInstructions(mac, "text"), tools);
  const out = await chunks(await transport.sendMessages(turn("아이폰 화면 읽어")));
  const types = out.map(chunk => chunk.type);
  assert.ok(types.includes("tool-input-available") && types.includes("tool-output-available"), types.join(","));
  const call = out.find(chunk => chunk.type === "tool-input-available");
  assert.ok(call && call.type === "tool-input-available" && call.toolName === "phone_screen");
  assert.equal(out.flatMap(chunk => chunk.type === "text-delta" ? [chunk.delta] : []).join(""), "홈 화면입니다.");
  assert.equal(out.at(-1)?.type, "finish");
  assert.deepEqual(progress.map(event => [event.name, event.status]), [["phone_screen", "running"], ["phone_screen", "success"]]);
  assert.equal(requests.length, 2);
  const first = requests[0] as { tools: { name: string }[]; model?: string };
  assert.ok(first.tools.some(tool => tool.name === "phone_screen"));
  assert.match(JSON.stringify(first), /phone_screen/);
  const second = requests[1] as { input: { type?: string; call_id?: string; output?: unknown }[] };
  assert.ok(second.input.some(item => item.type === "function_call_output" && item.call_id === "call_1" && String(item.output).includes("홈 화면")));
});

test("one chat line about a KB business account runs path_cold_start and stops at human login, with no secrets", async () => {
  const calls: { name: string; args: Record<string, unknown> }[] = [];
  let turnCount = 0;
  const bridge = new NativeBridge(raw => {
    const request = JSON.parse(raw) as { id: string; method: string; args: Record<string, unknown> };
    const reply = (result: unknown) => queueMicrotask(() => bridge.receive({ id: request.id, result }));
    if (request.method === "executeTool") {
      calls.push({ name: String(request.args.name), args: (request.args.args ?? {}) as Record<string, unknown> });
      return reply({ text: "멈춤: 사람 로그인(Face ID). 계좌·비밀은 읽지 않음. 메인 앱에서 실행(example 아님).", error: false });
    }
    const args = request.args as { path: string; body: Record<string, unknown> };
    if (args.path === "/v1/responses") {
      return reply(++turnCount === 1
        ? response([{ type: "function_call", id: "fc_kb", call_id: "call_kb", name: "path_cold_start", arguments: "{\"app\":\"kb-enterprise\"}", status: "completed" }])
        : response([{ type: "message", id: "msg_kb", role: "assistant", status: "completed", content: [{ type: "output_text", text: "Face ID로 로그인하면 이어서 볼게요. 계좌는 읽지 않았습니다.", annotations: [] }] }]));
    }
    throw new Error("unexpected " + request.method);
  });
  const tools = createAgentTools(mac, bridge, () => {}, () => {});
  const transport = createChatTransport(bridge, () => {}, "gpt-6-astra", voiceInstructions(mac, "text"), tools);
  assert.match(voiceInstructions(mac, "text"), /path_cold_start\(app: kb-enterprise\)/);
  assert.match(voiceInstructions(mac, "text"), /버튼을 누르라고 하지 말고/);
  const out = await chunks(await transport.sendMessages(turn("KB 사업자 계좌 읽어줘")));
  const call = out.find(chunk => chunk.type === "tool-input-available");
  assert.ok(call && call.type === "tool-input-available" && call.toolName === "path_cold_start");
  assert.deepEqual(calls, [{ name: "path_cold_start", args: { app: "kb-enterprise" } }]);
  const text = out.flatMap(chunk => chunk.type === "text-delta" ? [chunk.delta] : []).join("");
  assert.match(text, /Face ID/);
  assert.doesNotMatch(text, /123456|계좌번호|password|비밀번호/);
});

test("a proxy failure becomes one short error chunk, never a thrown provider payload", async () => {
  const bridge = new NativeBridge(raw => {
    const request = JSON.parse(raw) as { id: string };
    queueMicrotask(() => bridge.receive({ id: request.id, error: { code: "server_request_failed", message: "private upstream details" } }));
  });
  const transport = createChatTransport(bridge, () => {}, "gpt-6-astra", "테스트", createAgentTools(mac, bridge, () => {}, () => {}));
  const out = await chunks(await transport.sendMessages(turn("안녕")));
  const error = out.find(chunk => chunk.type === "error");
  assert.ok(error && error.type === "error");
  assert.ok(!error.errorText.includes("private"), error.errorText);
});
