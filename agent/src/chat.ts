// 텍스트 채팅은 Vercel AI SDK로 돈다. 번들 UI는 키를 갖지 않는다: 모델 호출은 네이티브 브리지 request → 앱 서버 /v1/responses → Vercel AI Gateway.
// 도구는 통화(Realtime)와 같은 정의(createAgentTools)를 그대로 감싼다. 대화 이력은 useChat이 들고, 세션이 끝나면 비운다.
import { createOpenAI } from "@ai-sdk/openai";
import { DirectChatTransport, ToolLoopAgent, jsonSchema, simulateStreamingMiddleware, stepCountIs, tool, wrapLanguageModel, type ChatTransport, type ToolSet, type UIMessage } from "ai";
import { RunContext, type Tool as AgentTool } from "@openai/agents";
import { NativeBridge, NativeBridgeError } from "./bridge";

/** A language model whose only transport is the native bridge; anything but a Responses POST is refused. */
export function bridgedModel(bridge: NativeBridge, check: () => void, model: string) {
  const transport: typeof fetch = async (url, init) => {
    check();
    const target = new URL(url instanceof Request ? url.url : String(url));
    if (target.pathname !== "/v1/responses" || (init?.method ?? "GET").toUpperCase() !== "POST") throw new NativeBridgeError("tool_failed");
    const body = init?.body ? JSON.parse(String(init.body)) as Record<string, unknown> : {};
    const json = await bridge.call<Record<string, unknown>>("request", { path: "/v1/responses", body }, 130_000);   // a flagship turn can take a minute
    check();
    return new Response(JSON.stringify(json), { status: 200, headers: { "content-type": "application/json" } });
  };
  const provider = createOpenAI({ apiKey: "native-bridge", baseURL: "https://native.invalid/v1", fetch: transport });
  // ponytail: the proxy answers whole responses; drop the middleware once /v1/responses relays SSE
  return wrapLanguageModel({ model: provider.responses(model), middleware: simulateStreamingMiddleware() });
}

/** The call's tool definitions reused for chat: same schemas, same native execution, same safe error strings. */
export function chatTools(tools: AgentTool[]): ToolSet {
  const context = new RunContext({});
  return Object.fromEntries(tools.flatMap(item => item.type !== "function" ? [] : [[item.name, tool({
    description: item.description,
    inputSchema: jsonSchema<Record<string, unknown>>(item.parameters as never),
    execute: input => item.invoke(context, JSON.stringify(input ?? {})),
  })]]));
}

/** Errors come from the SDK, the bridge or the app server (never screen data): keep a short reason so the person can report it. */
export function errorText(error: unknown, prefix = "응답 실패"): string {
  return error instanceof NativeBridgeError ? error.message : prefix + (error instanceof Error && error.message ? ` · ${error.message.slice(0, 200)}` : "");
}

export function createChatTransport(bridge: NativeBridge, check: () => void, model: string, instructions: string, tools: AgentTool[]): ChatTransport<UIMessage> {
  return new DirectChatTransport({
    agent: new ToolLoopAgent({ model: bridgedModel(bridge, check, model), instructions, tools: chatTools(tools), stopWhen: stepCountIs(40) }),
    onError: error => errorText(error),
  }) as ChatTransport<UIMessage>;
}
