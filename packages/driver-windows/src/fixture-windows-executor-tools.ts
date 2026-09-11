import type {
  WindowsActionResult,
  WindowsExecutorToolName,
  WindowsExecutorTools,
  WindowsScreenNode,
  WindowsScreenRead,
} from "./windows-executor-tools.ts";
import { WINDOWS_SNAPSHOT_TTL_MS, WindowsAdapterError } from "./windows-executor-tools.ts";

export interface FixtureWindowsWindow {
  readonly appLabel: string;
  readonly packageName: string;
  readonly nodes: readonly Omit<WindowsScreenNode, "id">[];
}

export interface FixtureWindowsOptions {
  /** Clock used for snapshot expiry; tests inject a fake one. */
  readonly now?: () => number;
  /** Snapshot lifetime; defaults to the measured executor value. */
  readonly snapshotTtlMs?: number;
}

export type FixtureWindowsCall =
  | { readonly name: "app_open"; readonly args: { readonly target: string } }
  | { readonly name: "screen_read"; readonly args: Record<string, never> }
  | { readonly name: "ui_tap"; readonly args: { readonly nodeId: string } }
  | { readonly name: "ui_type"; readonly args: { readonly nodeId: string; readonly text: string } };

/**
 * In-memory stand-in for `executors/windows` tools. No UIA, no device approval.
 * Mirrors the measured executor semantics: node ids are `"<snapshotId>:<index>"`, only the latest
 * snapshot is addressable, it expires after the TTL, and every `ui_tap`/`ui_type` invalidates it.
 */
export class FixtureWindowsExecutorTools implements WindowsExecutorTools {
  readonly calls: FixtureWindowsCall[] = [];
  private window: FixtureWindowsWindow;
  private lastNodes: WindowsScreenNode[] = [];
  private lastReadAt = Number.NEGATIVE_INFINITY;
  private reads = 0;
  private readonly now: () => number;
  private readonly snapshotTtlMs: number;

  constructor(window: FixtureWindowsWindow, options: FixtureWindowsOptions = {}) {
    this.window = window;
    this.now = options.now ?? Date.now;
    this.snapshotTtlMs = options.snapshotTtlMs ?? WINDOWS_SNAPSHOT_TTL_MS;
  }

  app_open(args: { target: string }): { packageName: string; activated: boolean } {
    this.calls.push({ name: "app_open", args: { target: args.target } });
    if (args.target !== this.window.appLabel && args.target !== this.window.packageName) {
      throw new WindowsAdapterError("app_not_found");
    }
    this.lastNodes = [];
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
      ...(node.role === undefined ? {} : { role: node.role }),
    }));
    this.lastReadAt = this.now();
    return {
      snapshotId,
      packageName: this.window.packageName,
      appLabel: this.window.appLabel,
      nodes: this.lastNodes,
      truncated: false,
    };
  }

  ui_tap(args: { nodeId: string }): WindowsActionResult & { invoked: boolean } {
    this.calls.push({ name: "ui_tap", args: { nodeId: args.nodeId } });
    const node = this.addressable(args.nodeId);
    if (!node.clickable) throw new WindowsAdapterError("protected_action");
    this.lastNodes = [];
    return { invoked: true, requiresScreenRead: true };
  }

  ui_type(args: { nodeId: string; text: string }): WindowsActionResult & { typed: boolean } {
    this.calls.push({ name: "ui_type", args: { nodeId: args.nodeId, text: args.text } });
    const node = this.addressable(args.nodeId);
    if (!node.editable) throw new WindowsAdapterError("protected_action");
    this.lastNodes = [];
    return { typed: true, requiresScreenRead: true };
  }

  /** The node must belong to the latest, unexpired, not-yet-acted-on snapshot. */
  private addressable(nodeId: string): WindowsScreenNode {
    if (this.now() - this.lastReadAt > this.snapshotTtlMs) throw new WindowsAdapterError("stale_screen", "snapshot expired");
    const node = this.lastNodes.find(item => item.id === nodeId);
    if (node === undefined) throw new WindowsAdapterError("stale_screen", "nodeId is not in the latest snapshot");
    return node;
  }
}

export function fixtureToolNames(calls: readonly FixtureWindowsCall[]): WindowsExecutorToolName[] {
  return calls.map(call => call.name);
}
