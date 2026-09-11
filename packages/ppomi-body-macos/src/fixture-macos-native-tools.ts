import type {
  MacNativeToolName,
  MacNativeTools,
  MacScreenNode,
  MacScreenRead,
} from "./macos-native-tools.ts";
import { MacosAdapterError } from "./macos-native-tools.ts";

export interface FixtureMacosWindow {
  readonly appLabel: string;
  readonly url?: string;
  readonly nodes: readonly Omit<MacScreenNode, "id">[];
}

export type FixtureMacosCall =
  | { readonly name: "browser_open"; readonly args: { readonly app?: string; readonly url?: string } }
  | { readonly name: "screen_read"; readonly args: Record<string, never> }
  | { readonly name: "ui_tap"; readonly args: { readonly nodeId: string } }
  | { readonly name: "ui_type"; readonly args: { readonly nodeId: string; readonly text: string } };

/** In-memory stand-in for Mac native tools. No Accessibility, no device approval. */
export class FixtureMacosNativeTools implements MacNativeTools {
  readonly calls: FixtureMacosCall[] = [];
  private window: FixtureMacosWindow;
  private lastNodes: MacScreenNode[] = [];
  private reads = 0;

  constructor(window: FixtureMacosWindow) {
    this.window = window;
  }

  browser_open(args: { app?: string; url?: string }): { opened: boolean; app: string } {
    this.calls.push({ name: "browser_open", args: { ...copyOpenArgs(args) } });
    const app = args.app;
    const url = args.url;
    const matchesApp = app !== undefined && app === this.window.appLabel;
    const matchesUrl = url !== undefined && url === this.window.url;
    if (!matchesApp && !matchesUrl) throw new MacosAdapterError("app_not_found");
    return { opened: true, app: this.window.appLabel };
  }

  screen_read(): MacScreenRead {
    this.calls.push({ name: "screen_read", args: {} });
    this.reads += 1;
    const snapshotId = `fixture-${this.reads}`;
    this.lastNodes = this.window.nodes.map((node, index) => ({
      id: `${snapshotId}:${index}`,
      text: node.text,
      clickable: node.clickable,
      editable: node.editable,
    }));
    return {
      snapshotId,
      appLabel: this.window.appLabel,
      nodes: this.lastNodes,
      truncated: false,
    };
  }

  ui_tap(args: { nodeId: string }): { invoked: boolean } {
    this.calls.push({ name: "ui_tap", args: { nodeId: args.nodeId } });
    const node = this.lastNodes.find(item => item.id === args.nodeId);
    if (node === undefined || !node.clickable) throw new MacosAdapterError("stale_screen");
    return { invoked: true };
  }

  ui_type(args: { nodeId: string; text: string }): { typed: boolean } {
    this.calls.push({ name: "ui_type", args: { nodeId: args.nodeId, text: args.text } });
    const node = this.lastNodes.find(item => item.id === args.nodeId);
    if (node === undefined || !node.editable) throw new MacosAdapterError("stale_screen");
    return { typed: true };
  }
}

export function fixtureToolNames(calls: readonly FixtureMacosCall[]): MacNativeToolName[] {
  return calls.map(call => call.name);
}

function copyOpenArgs(args: { app?: string; url?: string }): { app?: string; url?: string } {
  const copied: { app?: string; url?: string } = {};
  if (args.app !== undefined) copied.app = args.app;
  if (args.url !== undefined) copied.url = args.url;
  return copied;
}
