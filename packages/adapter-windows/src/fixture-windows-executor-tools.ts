import type {
  WindowsExecutorToolName,
  WindowsExecutorTools,
  WindowsScreenNode,
  WindowsScreenRead,
} from "./windows-executor-tools.ts";
import { WindowsAdapterError } from "./windows-executor-tools.ts";

export interface FixtureWindowsWindow {
  readonly appLabel: string;
  readonly packageName: string;
  readonly nodes: readonly Omit<WindowsScreenNode, "id">[];
}

export type FixtureWindowsCall =
  | { readonly name: "app_open"; readonly args: { readonly target: string } }
  | { readonly name: "screen_read"; readonly args: Record<string, never> }
  | { readonly name: "ui_tap"; readonly args: { readonly nodeId: string } }
  | { readonly name: "ui_type"; readonly args: { readonly nodeId: string; readonly text: string } };

/** In-memory stand-in for `executors/windows` tools. No UIA, no device approval. */
export class FixtureWindowsExecutorTools implements WindowsExecutorTools {
  readonly calls: FixtureWindowsCall[] = [];
  private window: FixtureWindowsWindow;
  private lastNodes: WindowsScreenNode[] = [];
  private reads = 0;

  constructor(window: FixtureWindowsWindow) {
    this.window = window;
  }

  app_open(args: { target: string }): { packageName: string; activated: boolean } {
    this.calls.push({ name: "app_open", args: { target: args.target } });
    if (args.target !== this.window.appLabel && args.target !== this.window.packageName) {
      throw new WindowsAdapterError("app_not_found");
    }
    return { packageName: this.window.packageName, activated: true };
  }

  screen_read(): WindowsScreenRead {
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
      packageName: this.window.packageName,
      appLabel: this.window.appLabel,
      nodes: this.lastNodes,
      truncated: false,
    };
  }

  ui_tap(args: { nodeId: string }): { invoked: boolean } {
    this.calls.push({ name: "ui_tap", args: { nodeId: args.nodeId } });
    const node = this.lastNodes.find(item => item.id === args.nodeId);
    if (node === undefined || !node.clickable) throw new WindowsAdapterError("stale_screen");
    return { invoked: true };
  }

  ui_type(args: { nodeId: string; text: string }): { typed: boolean } {
    this.calls.push({ name: "ui_type", args: { nodeId: args.nodeId, text: args.text } });
    const node = this.lastNodes.find(item => item.id === args.nodeId);
    if (node === undefined || !node.editable) throw new WindowsAdapterError("stale_screen");
    return { typed: true };
  }
}

export function fixtureToolNames(calls: readonly FixtureWindowsCall[]): WindowsExecutorToolName[] {
  return calls.map(call => call.name);
}
