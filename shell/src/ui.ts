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

function invoke(): Invoke {
  const core = (window as Window & { __TAURI__?: { core?: { invoke: Invoke } } }).__TAURI__?.core;
  if (core === undefined) {
    throw new Error("Tauri IPC is missing. Open this page through `npm --prefix shell run dev`.");
  }
  return core.invoke;
}

function el<K extends keyof HTMLElementTagNameMap>(id: K | string): HTMLElement {
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

async function run(): Promise<void> {
  const intent = (el("intent") as HTMLInputElement).value;
  const body = (el("body") as HTMLSelectElement).value;
  const live = (el("live") as HTMLInputElement).checked;
  const out = el("out");
  out.textContent = "running…";
  try {
    const result = await invoke()("run_path", { intent, body, live }) as SpineView;
    out.textContent = render(result);
  } catch (error) {
    out.textContent = error instanceof Error ? error.message : String(error);
  }
}

el("run").addEventListener("click", () => {
  void run();
});

el("intent").addEventListener("keydown", event => {
  if (event.key === "Enter") void run();
});
