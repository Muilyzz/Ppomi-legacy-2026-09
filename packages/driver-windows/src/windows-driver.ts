import type { OsUiDriver, ScreenSnapshot } from "../../playbook-runtime/src/index.ts";
import type {
  WindowsExecutorTools,
  WindowsScreenNode,
  WindowsScreenRead,
} from "./windows-executor-tools.ts";
import { WindowsDriverError } from "./windows-executor-tools.ts";

/**
 * `OsUiDriver` over `app_open` / `screen_read` / `ui_tap` / `ui_type`, bound to the runtime by `OsSurface`.
 * Does not talk to UIA itself and has no device-approval input.
 */
export class WindowsDriver implements OsUiDriver {
  readonly kind = "os-windows" as const;
  private readonly tools: WindowsExecutorTools;
  private lastFocused: string | null = null;
  private lastScreen: WindowsScreenRead | null = null;

  constructor(tools: WindowsExecutorTools) {
    this.tools = tools;
  }

  readScreen(): ScreenSnapshot {
    this.lastScreen = this.tools.screen_read();
    return toSnapshot(this.lastScreen, this.lastFocused);
  }

  focus(target: string): void {
    this.tools.app_open({ target });
    this.lastFocused = target;
    this.lastScreen = null;
  }

  click(target: string): void {
    const node = resolveNode(this.requireScreen(), target, "clickable");
    this.tools.ui_tap({ nodeId: node.id });
    this.lastFocused = target;
    this.lastScreen = null;
  }

  type(target: string, text: string): void {
    const node = resolveNode(this.requireScreen(), target, "editable");
    this.tools.ui_type({ nodeId: node.id, text });
    this.lastFocused = target;
    this.lastScreen = null;
  }

  private requireScreen(): WindowsScreenRead {
    if (this.lastScreen !== null) return this.lastScreen;
    this.lastScreen = this.tools.screen_read();
    return this.lastScreen;
  }
}

function toSnapshot(screen: WindowsScreenRead, lastFocused: string | null): ScreenSnapshot {
  const texts: string[] = [];
  addText(texts, screen.appLabel);
  for (const node of screen.nodes) addText(texts, node.text);
  return {
    title: screen.appLabel,
    texts,
    focused: lastFocused,
  };
}

function addText(texts: string[], value: string): void {
  const text = value.trim();
  if (text.length === 0 || texts.includes(text)) return;
  texts.push(text);
}

function resolveNode(
  screen: WindowsScreenRead,
  target: string,
  need: "clickable" | "editable",
): WindowsScreenNode {
  const matches = screen.nodes.filter(node => node.text === target);
  if (matches.length === 0) throw new WindowsDriverError("target_not_on_screen", `target not on screen: ${target}`);
  const usable = matches.filter(node => (need === "clickable" ? node.clickable : node.editable));
  if (usable.length === 0) throw new WindowsDriverError("protected_action", `target not ${need}: ${target}`);
  if (usable.length !== 1) throw new WindowsDriverError("ambiguous_target", `ambiguous target: ${target}`);
  return usable[0]!;
}
