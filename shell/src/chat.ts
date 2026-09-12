import { invokeRunPath, linesFromSpine, textFromSpine, type Line, type SpineTool, type SpineView } from "./spine.ts";

const MATCH_KB_OPEN = /kb스타기업뱅킹|kb\s*사업자\s*홈|path_cold_start|kb-enterprise/i;

export const CEO_GATEWAY_PROMPT = "KB스타비즈에 넣어둔 번호 마지막만 보여줘";
export const SECRETS_CATALOG_INTENT = "사업자 계좌번호";
export const GATEWAY_FAIL_TEXT = "모델 연결에 실패했습니다.";

const TEXT_MODEL = "openai/gpt-6-astra";
const INSTRUCTIONS = [
  "You are 뽀미 in the Mac conversation shell.",
  "Call run_path when the person wants a host path.",
  "Home / next / browse → intent 다음.",
  "KB스타기업뱅킹 열어 / KB 사업자 홈 / path_cold_start → pass the spoken intent.",
  "Saved business or KB account / KB스타비즈 / 넣어둔 번호 / last four digits → intent 사업자 계좌번호.",
  "Never write a full account number. Only ****last4 from the tool result.",
].join(" ");

const RUN_PATH_TOOL = {
  type: "function",
  name: "run_path",
  description: "Run a Ppomi host path (Home next, business-account secret, KB스타기업뱅킹). Pass a catalog intent.",
  parameters: {
    type: "object",
    additionalProperties: false,
    properties: {
      intent: { type: "string", description: "Catalog intent such as 다음 or 사업자 계좌번호" },
    },
    required: ["intent"],
  },
} as const;

type ResponsesOutput = {
  readonly type?: string;
  readonly call_id?: string;
  readonly name?: string;
  readonly arguments?: string;
  readonly content?: readonly { readonly type?: string; readonly text?: string }[];
};

export type ResponsesBody = { readonly output?: readonly ResponsesOutput[] };

export type GatewayProxy = {
  readonly configured: boolean;
  readonly fixture?: boolean;
  readonly response?: ResponsesBody;
  readonly error?: string;
};

export type ChatTurn = {
  readonly mode: "gateway" | "local";
  readonly lines: Line[];
};

export type CompleteFn = (body: Record<string, unknown>) => Promise<ResponsesBody | null>;
export type RunPathFn = (intent: string) => Promise<SpineView>;

type Invoke = (cmd: string, args: Record<string, unknown>) => Promise<unknown>;

function tauriInvoke(): Invoke | null {
  const core = (globalThis as { __TAURI__?: { core?: { invoke: Invoke } } }).__TAURI__?.core;
  return core?.invoke ?? null;
}

function previewFixture(): boolean {
  const href = (globalThis as { location?: { search?: string } }).location?.search;
  return href !== undefined && new URLSearchParams(href).get("chat") === "fixture";
}

export function redactSecrets(text: string): string {
  return text
    .replace(/001234567890/g, "****7890")
    .replace(/\d{6,}/g, digits => `****${digits.slice(-4)}`);
}

export function redactSpine(result: SpineView): SpineView {
  return JSON.parse(redactSecrets(JSON.stringify(result))) as SpineView;
}

function userTextFromInput(input: unknown): string {
  if (typeof input === "string") return input;
  if (!Array.isArray(input)) return "";
  for (const item of input) {
    if (item && typeof item === "object" && "content" in item && typeof item.content === "string") {
      return item.content;
    }
  }
  return "";
}

function hasToolOutput(input: unknown): boolean {
  return Array.isArray(input) && input.some(item => item && typeof item === "object" && item.type === "function_call_output");
}

function toolOutputText(input: unknown): string {
  if (!Array.isArray(input)) return "";
  const row = input.find(item => item && typeof item === "object" && item.type === "function_call_output") as
    | { output?: unknown }
    | undefined;
  return typeof row?.output === "string" ? row.output : JSON.stringify(row?.output ?? "");
}

/** Offline stand-in for a Gateway Responses turn. Maps paraphrases itself — not the local MATCH_SECRETS regex. */
export function fixtureIntent(text: string): string {
  const trimmed = text.trim();
  if (/^(다음|browse|next|열어|home)$/i.test(trimmed)) return "다음";
  if (MATCH_KB_OPEN.test(trimmed)) return trimmed;
  if (/스타비즈|마지막|last\s*4|digits|넣어둔|번호|사업자|계좌|account|kb/i.test(trimmed)) {
    return SECRETS_CATALOG_INTENT;
  }
  return trimmed;
}

export function fixtureResponses(body: Record<string, unknown>): ResponsesBody {
  if (hasToolOutput(body.input)) {
    const blob = toolOutputText(body.input);
    let text = "그 일에 맞는 경로가 아직 없습니다.";
    try {
      text = textFromSpine(JSON.parse(blob) as SpineView);
    } catch {
      const masked = blob.match(/\*{4}\d{4}/);
      if (masked !== null) text = `저장된 사업자 계좌는 \`${masked[0]}\`입니다.`;
      else if (blob.includes("path-home-next")) text = "다음을 눌렀습니다.";
    }
    return { output: [{ type: "message", content: [{ type: "output_text", text }] }] };
  }
  const intent = fixtureIntent(userTextFromInput(body.input));
  return {
    output: [{
      type: "function_call",
      call_id: "call_run_path",
      name: "run_path",
      arguments: JSON.stringify({ intent }),
    }],
  };
}

export function functionCallOf(response: ResponsesBody): { call_id: string; name: string; intent: string } | null {
  const call = (response.output ?? []).find(item => item.type === "function_call" && item.name === "run_path");
  if (call === undefined) return null;
  let intent = "";
  try {
    const args = JSON.parse(call.arguments ?? "{}") as { intent?: unknown };
    intent = typeof args.intent === "string" ? args.intent.trim() : "";
  } catch {
    intent = "";
  }
  if (intent === "") return null;
  return { call_id: call.call_id ?? "call_run_path", name: "run_path", intent };
}

export function assistantTextOf(response: ResponsesBody): string {
  return (response.output ?? []).flatMap(item =>
    item.type === "message" && Array.isArray(item.content)
      ? item.content.flatMap(part => part.type === "output_text" && part.text ? [part.text] : [])
      : [],
  ).join("");
}

export function toolFromModelCall(call: { name: string; intent: string }, result: SpineView): SpineTool {
  const safe = redactSpine(result);
  const failed = (safe.status !== "completed" && safe.status !== "needs_human") || safe.pathId === null;
  return {
    name: call.name,
    label: safe.pathId ?? call.name,
    state: failed ? "output-error" : "output-available",
    input: { intent: call.intent, via: "gateway" },
    output: safe.body ?? { status: safe.status, note: safe.note },
    ...(failed ? { errorText: safe.note } : {}),
  };
}

export function responsesRequest(text: string, extraInput: readonly Record<string, unknown>[] = []): Record<string, unknown> {
  return {
    model: TEXT_MODEL,
    instructions: INSTRUCTIONS,
    tools: [RUN_PATH_TOOL],
    input: [{ role: "user", content: text }, ...extraInput],
    stream: false,
    store: false,
  };
}

export async function defaultComplete(body: Record<string, unknown>): Promise<ResponsesBody | null> {
  if (previewFixture()) return fixtureResponses(body);
  const invoke = tauriInvoke();
  if (invoke !== null) {
    let proxy: GatewayProxy;
    try {
      proxy = await invoke("ai_gateway", { body }) as GatewayProxy;
    } catch {
      throw new Error("gateway_ipc_failed");
    }
    if (proxy.fixture) return proxy.response ?? fixtureResponses(body);
    if (!proxy.configured) return null;
    if (proxy.error !== undefined || proxy.response === undefined) {
      throw new Error(proxy.error ?? "model_unavailable");
    }
    return proxy.response;
  }
  const response = await fetch("/__ppomi/responses", {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify(body),
  });
  if (response.status === 503) return null;
  if (!response.ok) throw new Error("모델 응답을 받지 못했습니다.");
  return await response.json() as ResponsesBody;
}

export async function sendChat(
  text: string,
  deps: { complete?: CompleteFn; runPath?: RunPathFn } = {},
): Promise<ChatTurn> {
  const complete = deps.complete ?? defaultComplete;
  const runPath = deps.runPath ?? invokeRunPath;
  let first: ResponsesBody | null;
  try {
    first = await complete(responsesRequest(text));
  } catch {
    const spine = await runPath(text);
    if (spine.status === "path_not_found") {
      return { mode: "gateway", lines: [{ kind: "bubble", role: "assistant", text: GATEWAY_FAIL_TEXT }] };
    }
    return { mode: "local", lines: linesFromSpine(spine) };
  }
  if (first === null) return { mode: "local", lines: linesFromSpine(await runPath(text)) };

  const call = functionCallOf(first);
  if (call === null) {
    const spoken = redactSecrets(assistantTextOf(first) || "응답이 비어 있습니다.");
    return { mode: "gateway", lines: [{ kind: "bubble", role: "assistant", text: spoken }] };
  }

  const spine = await runPath(call.intent);
  const safe = redactSpine(spine);
  let follow: ResponsesBody | null = null;
  try {
    follow = await complete(responsesRequest(text, [
      { type: "function_call", call_id: call.call_id, name: call.name, arguments: JSON.stringify({ intent: call.intent }) },
      { type: "function_call_output", call_id: call.call_id, output: JSON.stringify(safe) },
    ]));
  } catch {
    follow = null;
  }
  const spoken = redactSecrets(assistantTextOf(follow ?? {}) || textFromSpine(safe));
  return {
    mode: "gateway",
    lines: [
      { kind: "tool", tool: toolFromModelCall(call, safe) },
      { kind: "bubble", role: "assistant", text: spoken },
    ],
  };
}
