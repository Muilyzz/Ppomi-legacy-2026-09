import type { OsUiDriver, ScreenSnapshot } from "../../ppomi-body/src/index.ts";
import type {
  MacNativeTools,
  MacScreenNode,
  MacScreenRead,
} from "./macos-native-tools.ts";
import { MacosAdapterError } from "./macos-native-tools.ts";

/**
 * `OsUiDriver` over Mac `browser_open` / `screen_read` / `ui_tap` / `ui_type`.
 * `focus` names an already-running app; it is never `browser_open({ url })`.
 */
export class MacosDriver implements OsUiDriver {
  readonly kind = "os-macos" as const;
  private readonly tools: MacNativeTools;
  private lastFocused: string | null = null;
  private lastScreen: MacScreenRead | null = null;

  constructor(tools: MacNativeTools) {
    this.tools = tools;
  }

  readScreen(): ScreenSnapshot {
    this.lastScreen = this.tools.screen_read();
    return toSnapshot(this.lastScreen, this.lastFocused);
  }

  focus(target: string): void {
    this.tools.browser_open({ app: target });
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

  private requireScreen(): MacScreenRead {
    if (this.lastScreen !== null) return this.lastScreen;
    this.lastScreen = this.tools.screen_read();
    return this.lastScreen;
  }
}

/** @deprecated Renamed to `MacosDriver`. */
export const MacosAdapter = MacosDriver;

function toSnapshot(screen: MacScreenRead, lastFocused: string | null): ScreenSnapshot {
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
  screen: MacScreenRead,
  target: string,
  need: "clickable" | "editable",
): MacScreenNode {
  const matches = screen.nodes.filter(node => node.text === target);
  if (matches.length === 0) throw new MacosAdapterError("target_not_on_screen", `target not on screen: ${target}`);
  const usable = matches.filter(node => (need === "clickable" ? node.clickable : node.editable));
  if (usable.length === 0) throw new MacosAdapterError("protected_action", `target not ${need}: ${target}`);
  if (usable.length !== 1) throw new MacosAdapterError("ambiguous_target", `ambiguous target: ${target}`);
  return usable[0]!;
}
