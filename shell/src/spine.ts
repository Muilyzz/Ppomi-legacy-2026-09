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

function tauriInvoke(): Invoke | null {
  const core = (globalThis as { __TAURI__?: { core?: { invoke: Invoke } } }).__TAURI__?.core;
  return core?.invoke ?? null;
}

/** Browser / `vite preview` only. Packaged Tauri always has IPC. */
export function previewSpine(intent: string, body = "macos"): SpineView {
  if (!MATCH_HOME.test(intent.trim())) {
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

export async function invokeRunPath(intent: string, body = "macos", live = false): Promise<SpineView> {
  const invoke = tauriInvoke();
  if (invoke === null) return previewSpine(intent, body);
  return invoke("run_path", { intent, body, live }) as Promise<SpineView>;
}

export function textFromSpine(result: SpineView): string {
  switch (result.status) {
    case "path_not_found":
      return "그 일에 맞는 경로가 아직 없습니다.";
    case "grant_denied":
      return "권한이 없어 멈추었습니다.";
    case "needs_human":
      return "사람 차례입니다.";
    case "protected":
      return "보호된 동작이라 멈추었습니다.";
    case "failed":
      return "실행에 실패했습니다.";
    case "completed":
      return result.pathId === "path-home-next" ? "다음을 눌렀습니다." : "실행했습니다.";
    default: {
      const exhaustive: never = result.status;
      return exhaustive;
    }
  }
}

export function toolFromSpine(result: SpineView): SpineTool | null {
  if (result.status === "path_not_found" || result.pathId === null) return null;
  const failed = result.status !== "completed";
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
