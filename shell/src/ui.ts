type Invoke = (cmd: string, args: Record<string, unknown>) => Promise<unknown>;

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
  const steps = result.body?.steps ?? [];
  const rows = steps
    .map(step => `  - ${step.stepId}  ${step.status}  ${step.note}`)
    .join("\n");
  return [
    `status   ${result.status}`,
    `path     ${result.pathId ?? "(none)"}`,
    `body     ${result.bodyKind}${result.live ? " live" : " fixture"}`,
    `note     ${result.note}`,
    rows,
    `hook     ${result.hook}`,
  ].filter(line => line.length > 0).join("\n");
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
