// 텍스트 채팅을 최상위 GPT(Responses API)로 돌리는 루프. 번들 UI는 키를 갖지 않는다: 모든 모델 호출은 네이티브 브리지 request → 앱 서버의 /v1/responses 프록시로 간다.
// 도구는 Realtime 세션과 같은 정의(createAgentTools)를 그대로 쓰고, 대화 이력은 이 객체 안에만 있다(세션이 끝나면 사라진다).
import OpenAI from "openai";
import { Agent, OpenAIProvider, Runner, type AgentInputItem, type Tool } from "@openai/agents";
import { NativeBridge, NativeBridgeError } from "./bridge";
import type { ChatMessage } from "./voice";

/** An OpenAI client whose only transport is the native bridge; anything but a Responses POST is refused. */
export function bridgedOpenAI(bridge: NativeBridge, check: () => void) {
  const transport = (async (url: RequestInfo | URL, init?: RequestInit) => {
    check();
    const target = new URL(url instanceof Request ? url.url : String(url));
    if (target.pathname !== "/v1/responses" || (init?.method ?? "GET").toUpperCase() !== "POST") throw new NativeBridgeError("tool_failed");
    const body = init?.body ? JSON.parse(String(init.body)) as Record<string, unknown> : {};
    const json = await bridge.call<Record<string, unknown>>("request", { path: "/v1/responses", body }, 130_000);   // a flagship turn can take a minute
    check();
    return new Response(JSON.stringify(json), { status: 200, headers: { "content-type": "application/json" } });
  }) as typeof fetch;
  return new OpenAI({ apiKey: "native-bridge", baseURL: "https://native.invalid/v1", dangerouslyAllowBrowser: true, fetch: transport, maxRetries: 0 });
}

/** Only conversation text becomes chat rows; function calls, their outputs and reasoning items never do. */
export function chatMessagesFromItems(items: AgentInputItem[]): ChatMessage[] {
  return items.flatMap((item, index): ChatMessage[] => {
    const record = item as { type?: string; role?: string; content?: unknown; id?: string; status?: string };
    if ((record.type ?? "message") !== "message" || (record.role !== "user" && record.role !== "assistant")) return [];
    const text = typeof record.content === "string" ? record.content
      : Array.isArray(record.content) ? record.content.flatMap((part) => {
        const content = part as { type?: string; text?: unknown };
        return (content.type === "input_text" || content.type === "output_text") && typeof content.text === "string" ? [content.text] : [];
      }).join("") : "";
    const status = record.status === "in_progress" || record.status === "incomplete" ? record.status : "completed";
    return text ? [{ id: record.id ?? `item-${index}`, role: record.role, text, status }] : [];
  });
}

export class ResponsesChat {
  private history: AgentInputItem[] = [];
  private readonly agent: Agent;
  private readonly runner: Runner;
  constructor(bridge: NativeBridge, check: () => void, model: string, instructions: string, tools: Tool[]) {
    this.agent = new Agent({ name: "뽀미", instructions, tools, model });
    this.runner = new Runner({ modelProvider: new OpenAIProvider({ openAIClient: bridgedOpenAI(bridge, check), useResponses: true }), tracingDisabled: true });
  }
  get messages(): ChatMessage[] { return chatMessagesFromItems(this.history); }
  /** One user turn: the runner loops model ↔ tools until a final message, then the whole history is the new context. */
  async send(text: string): Promise<ChatMessage[]> {
    const input: AgentInputItem[] = [...this.history, { role: "user", content: text }];
    const result = await this.runner.run(this.agent, input, { maxTurns: 40 });
    this.history = result.history;
    return this.messages;
  }
}
