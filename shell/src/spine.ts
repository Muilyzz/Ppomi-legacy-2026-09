export type SpineStatus =
  | "completed"
  | "path_not_found"
  | "grant_denied"
  | "needs_human"
  | "protected"
  | "failed";

export interface SpineView {
  readonly status: SpineStatus;
  readonly pathId: string | null;
  readonly note: string;
  readonly bodyKind: string;
  readonly live: boolean;
  readonly hook: string;
  readonly body?: {
    readonly status: string;
    readonly steps: readonly { readonly stepId: string; readonly status: string; readonly note: string }[];
  } | null;
}

export type ToolState = "output-available" | "output-error" | "input-available";

export interface SpineTool {
  readonly name: string;
  readonly label: string;
  readonly state: ToolState;
  readonly input?: unknown;
  readonly output?: unknown;
  readonly errorText?: string;
}

export type Line =
  | { readonly kind: "bubble"; readonly role: "user" | "assistant"; readonly text: string }
  | { readonly kind: "tool"; readonly tool: SpineTool };

type Invoke = (cmd: string, args: Record<string, unknown>) => Promise<unknown>;

const MATCH_HOME = /^(다음|browse|next|열어|home)$/i;
const MATCH_KB = /kb스타기업뱅킹|kb\s*사업자\s*홈|path_cold_start|kb-enterprise/i;
const MATCH_SECRETS =
  /사업자\s*계좌|사업자\s*kb|kb\s*계좌|kb\s*account|계좌번호|통장번호|account\s*number|\baccount\b|계좌/i;

const KB_PATH_ID = "kb-star-biz-iphone";
const SECRETS_PATH_ID = "path-secrets-account";
const SECRETS_MASK = "****7890";
const SECRETS_KEY = "ppomi/kb-star-biz/account";
const KB_BUBBLE = "KB스타기업뱅킹을 열었습니다. Face ID로 로그인하면 이어서 볼게요.";

function tauriInvoke(): Invoke | null {
  const core = (globalThis as { __TAURI__?: { core?: { invoke: Invoke } } }).__TAURI__?.core;
  return core?.invoke ?? null;
}

/** Browser / `vite preview` only. Packaged Tauri always has IPC. */
export function previewSpine(intent: string, body = "macos"): SpineView {
  const text = intent.trim();
  if (MATCH_KB.test(text)) {
    return {
      status: "needs_human",
      pathId: KB_PATH_ID,
      note: "fixture: Home → KB스타기업뱅킹. Face ID·로그인은 당사자.",
      bodyKind: body,
      live: false,
      hook: "",
      body: {
        status: "stopped",
        steps: [
          { stepId: "go-home", status: "ok", note: "phone_key home" },
          { stepId: "open-kb", status: "ok", note: "KB스타기업뱅킹" },
          { stepId: "human-login", status: "needs_human", note: "Face ID·로그인은 당사자." },
        ],
      },
    };
  }
  if (MATCH_HOME.test(text)) {
    return {
      status: "completed",
      pathId: "path-home-next",
      note: "clicked Next",
      bodyKind: body,
      live: false,
      hook: "",
      body: {
        status: "completed",
        steps: [{ stepId: "open-next", status: "ok", note: "clicked Next" }],
      },
    };
  }
  if (MATCH_SECRETS.test(text)) {
    const note = `${SECRETS_MASK} ${SECRETS_KEY}`;
    return {
      status: "completed",
      pathId: SECRETS_PATH_ID,
      note,
      bodyKind: body,
      live: false,
      hook: "",
      body: {
        status: "completed",
        steps: [{ stepId: "read-account", status: "ok", note }],
      },
    };
  }
  return {
    status: "path_not_found",
    pathId: null,
    note: "no path matched the intent",
    bodyKind: body,
    live: false,
    hook: "",
    body: null,
  };
}

export async function invokeRunPath(intent: string, body = "macos", live = false): Promise<SpineView> {
  const invoke = tauriInvoke();
  if (invoke === null) return previewSpine(intent, body);
  try {
    return await invoke("run_path", { intent, body, live }) as SpineView;
  } catch {
    return previewSpine(intent, body);
  }
}

export function textFromSpine(result: SpineView): string {
  switch (result.status) {
    case "path_not_found":
      return "그 일에 맞는 경로가 아직 없습니다.";
    case "grant_denied":
      return "권한이 없어 멈추었습니다.";
    case "needs_human":
      if (result.pathId === KB_PATH_ID) return KB_BUBBLE;
      return "사람 차례입니다.";
    case "protected":
      return "보호된 동작이라 멈추었습니다.";
    case "failed":
      return "실행에 실패했습니다.";
    case "completed":
      if (result.pathId === "path-home-next") return "다음을 눌렀습니다.";
      if (result.pathId === SECRETS_PATH_ID) return secretsBubble(result);
      if (result.pathId === KB_PATH_ID) return KB_BUBBLE;
      return "실행했습니다.";
    default: {
      const exhaustive: never = result.status;
      return exhaustive;
    }
  }
}

function secretsBubble(result: SpineView): string {
  const blob = `${result.note} ${result.body?.steps.map(step => step.note).join(" ") ?? ""}`;
  const masked = blob.match(/\*{4}\d{4}/);
  // Bubble is markdown; backticks keep ****last4 visible.
  if (masked !== null) return `저장된 사업자 계좌는 \`${masked[0]}\`입니다.`;
  return "저장된 사업자 계좌가 없습니다.";
}

export function toolFromSpine(result: SpineView): SpineTool | null {
  if (result.status === "path_not_found" || result.pathId === null) return null;
  const failed = result.status !== "completed" && result.status !== "needs_human";
  return {
    name: "run_path",
    label: result.pathId,
    state: failed ? "output-error" : "output-available",
    input: { body: result.bodyKind, live: result.live },
    output: result.body ?? { status: result.status, note: result.note },
    ...(failed ? { errorText: result.note } : {}),
  };
}

export function linesFromSpine(result: SpineView): Line[] {
  const tool = toolFromSpine(result);
  const bubble: Line = { kind: "bubble", role: "assistant", text: textFromSpine(result) };
  return tool === null ? [bubble] : [{ kind: "tool", tool }, bubble];
}
