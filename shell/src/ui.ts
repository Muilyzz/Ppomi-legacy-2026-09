type Invoke = (cmd: string, args: Record<string, unknown>) => Promise<unknown>;

interface StepRowView {
  readonly stepId: string;
  readonly driver: string;
  readonly status: string;
  readonly attempt: string;
  readonly code?: string;
  readonly observation: { readonly summary: string };
}

interface SpineView {
  readonly status: string;
  readonly pathId: string | null;
  readonly note: string;
  readonly bodyKind: string;
  readonly live: boolean;
  readonly hook: string;
  readonly body?: {
    readonly status: string;
    readonly steps: readonly { readonly stepId: string; readonly status: string; readonly note: string }[];
  } | null;
  /** Core `RunResult`; `null` when the body stopped before `Runtime` (refusal, skip, path miss). */
  readonly run?: { readonly status: string; readonly stepResults: readonly StepRowView[] } | null;
}

interface Line {
  readonly role: "user" | "assistant";
  readonly text: string;
}

const lines: Line[] = [];

function invoke(): Invoke {
  const core = (window as Window & { __TAURI__?: { core?: { invoke: Invoke } } }).__TAURI__?.core;
  if (core === undefined) {
    throw new Error("Tauri IPC is missing. Open this page through `npm --prefix shell run dev`.");
  }
  return core.invoke;
}

function el(id: string): HTMLElement {
  const node = document.getElementById(id);
  if (node === null) throw new Error(`missing #${id}`);
  return node;
}

function render(result: SpineView): string {
  const run = result.run ?? null;
  const rows = run !== null
    ? run.stepResults.map(row =>
      `  - ${row.stepId}  ${row.status}  ${row.attempt}  ${row.driver}${row.code !== undefined ? `  ${row.code}` : ""}  ${row.observation.summary}`)
    : (result.body?.steps ?? []).map(step => `  - ${step.stepId}  ${step.status}  ${step.note}`);
  return [
    `status   ${result.status}`,
    `path     ${result.pathId ?? "(none)"}`,
    `body     ${result.bodyKind}${result.live ? " live" : " fixture"}`,
    `run      ${run !== null ? run.status : "(stopped before Runtime)"}`,
    `note     ${result.note}`,
    ...rows,
    `hook     ${result.hook}`,
  ].join("\n");
}

function paint(): void {
  const log = el("log");
  log.replaceChildren();
  for (const line of lines) {
    const p = document.createElement("p");
    p.dataset.role = line.role;
    p.textContent = line.text;
    log.append(p);
  }
  log.scrollTop = log.scrollHeight;
}

async function send(): Promise<void> {
  const input = el("intent") as HTMLInputElement;
  const text = input.value.trim();
  if (text.length === 0) return;
  input.value = "";
  lines.push({ role: "user", text });
  paint();
  try {
    const result = await invoke()("run_path", { intent: text, body: "macos", live: false }) as SpineView;
    lines.push({ role: "assistant", text: render(result) });
  } catch (error) {
    lines.push({ role: "assistant", text: error instanceof Error ? error.message : String(error) });
  }
  paint();
}

el("composer").addEventListener("submit", event => {
  event.preventDefault();
  void send();
});
