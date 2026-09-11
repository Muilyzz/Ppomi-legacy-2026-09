import type { OsAdapter, ScreenSnapshot } from "../../playbook-runtime/src/index.ts";
import type {
  AndroidNativeTools,
  AndroidScreenNode,
  AndroidScreenRead,
} from "./android-native-tools.ts";
import { AndroidAdapterError, isAndroidOpenPackage } from "./android-native-tools.ts";

/**
 * `OsAdapter` over `android_open` / `android_screen` / `android_click` / `android_type`.
 * Does not talk to Accessibility itself and has no device-approval or payment input.
 */
export class AndroidAdapter implements OsAdapter {
  private readonly tools: AndroidNativeTools;
  private lastFocused: string | null = null;
  private lastScreen: AndroidScreenRead | null = null;

  constructor(tools: AndroidNativeTools) {
    this.tools = tools;
  }

  readScreen(): ScreenSnapshot {
    this.lastScreen = this.tools.android_screen();
    return toSnapshot(this.lastScreen, this.lastFocused);
  }

  focus(target: string): void {
    const packageName = resolveOpenPackage(this.requireScreen(), target);
    this.tools.android_open({ packageName });
    this.lastFocused = target;
    this.lastScreen = null;
  }

  click(target: string): void {
    const node = resolveNode(this.requireScreen(), target, "clickable");
    this.tools.android_click({ nodeId: node.id });
    this.lastFocused = target;
    this.lastScreen = null;
  }

  type(target: string, text: string): void {
    const node = resolveNode(this.requireScreen(), target, "editable");
    if (node.password === true) {
      throw new AndroidAdapterError("protected_action", `password field is not supported: ${target}`);
    }
    this.tools.android_type({ nodeId: node.id, text });
    this.lastFocused = target;
    this.lastScreen = null;
  }

  private requireScreen(): AndroidScreenRead {
    if (this.lastScreen !== null) return this.lastScreen;
    this.lastScreen = this.tools.android_screen();
    return this.lastScreen;
  }
}

function toSnapshot(screen: AndroidScreenRead, lastFocused: string | null): ScreenSnapshot {
  const texts: string[] = [];
  addText(texts, screen.appLabel);
  for (const node of screen.nodes) {
    if (node.password === true) {
      addText(texts, "[redacted]");
      continue;
    }
    addText(texts, node.text);
    if (node.contentDescription !== undefined) addText(texts, node.contentDescription);
  }
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

function resolveOpenPackage(screen: AndroidScreenRead, target: string): string {
  if (isAndroidOpenPackage(target)) return target;
  if (target === screen.appLabel || target === screen.packageName) return screen.packageName;
  throw new AndroidAdapterError("app_not_found", `target not an openable Android app: ${target}`);
}

function nodeMatches(node: AndroidScreenNode, target: string): boolean {
  return node.text === target || node.contentDescription === target;
}

function resolveNode(
  screen: AndroidScreenRead,
  target: string,
  need: "clickable" | "editable",
): AndroidScreenNode {
  const matches = screen.nodes.filter(node => nodeMatches(node, target));
  if (matches.length === 0) {
    throw new AndroidAdapterError("target_not_on_screen", `target not on screen: ${target}`);
  }
  const usable = matches.filter(node => (need === "clickable" ? node.clickable : node.editable));
  if (usable.length === 0) {
    throw new AndroidAdapterError("protected_action", `target not ${need}: ${target}`);
  }
  if (usable.length !== 1) {
    throw new AndroidAdapterError("ambiguous_target", `ambiguous target: ${target}`);
  }
  return usable[0]!;
}
