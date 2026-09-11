import type {
  AndroidNativeToolName,
  AndroidNativeTools,
  AndroidScreenNode,
  AndroidScreenRead,
} from "./android-native-tools.ts";
import { AndroidAdapterError, isAndroidOpenPackage } from "./android-native-tools.ts";

export interface FixtureAndroidWindow {
  readonly appLabel: string;
  readonly packageName: string;
  readonly nodes: readonly Omit<AndroidScreenNode, "id">[];
}

export type FixtureAndroidCall =
  | { readonly name: "android_open"; readonly args: { readonly packageName: string } }
  | { readonly name: "android_screen"; readonly args: Record<string, never> }
  | { readonly name: "android_click"; readonly args: { readonly nodeId: string } }
  | { readonly name: "android_type"; readonly args: { readonly nodeId: string; readonly text: string } };

/** In-memory stand-in for Ppomi `android_*` tools. No device, no ADB, no payment bypass. */
export class FixtureAndroidNativeTools implements AndroidNativeTools {
  readonly calls: FixtureAndroidCall[] = [];
  private window: FixtureAndroidWindow;
  private lastNodes: AndroidScreenNode[] = [];
  private reads = 0;

  constructor(window: FixtureAndroidWindow) {
    this.window = window;
  }

  android_open(args: { packageName: string }): { opened: string } {
    this.calls.push({ name: "android_open", args: { packageName: args.packageName } });
    if (!isAndroidOpenPackage(args.packageName)) {
      throw new AndroidAdapterError("app_not_allowed", `android_open refused ${args.packageName}`);
    }
    if (args.packageName !== this.window.packageName) {
      throw new AndroidAdapterError("app_not_found", `android_open fixture has ${this.window.packageName}`);
    }
    return { opened: this.window.packageName };
  }

  android_screen(): AndroidScreenRead {
    this.calls.push({ name: "android_screen", args: {} });
    this.reads += 1;
    const snapshotId = `fixture-${this.reads}`;
    this.lastNodes = this.window.nodes.map((node, index) => copyNode(`${snapshotId}:${index}`, node));
    return {
      snapshotId,
      packageName: this.window.packageName,
      appLabel: this.window.appLabel,
      nodes: this.lastNodes,
      truncated: false,
    };
  }

  android_click(args: { nodeId: string }): { invoked: boolean } {
    this.calls.push({ name: "android_click", args: { nodeId: args.nodeId } });
    const node = this.lastNodes.find(item => item.id === args.nodeId);
    if (node === undefined || !node.clickable) throw new AndroidAdapterError("stale_screen");
    return { invoked: true };
  }

  android_type(args: { nodeId: string; text: string }): { typed: boolean } {
    this.calls.push({ name: "android_type", args: { nodeId: args.nodeId, text: args.text } });
    const node = this.lastNodes.find(item => item.id === args.nodeId);
    if (node === undefined || !node.editable || node.password === true) {
      throw new AndroidAdapterError("stale_screen");
    }
    return { typed: true };
  }
}

export function fixtureToolNames(calls: readonly FixtureAndroidCall[]): AndroidNativeToolName[] {
  return calls.map(call => call.name);
}

function copyNode(id: string, node: Omit<AndroidScreenNode, "id">): AndroidScreenNode {
  const copied: {
    id: string;
    text: string;
    clickable: boolean;
    editable: boolean;
    contentDescription?: string;
    password?: boolean;
  } = {
    id,
    text: node.text,
    clickable: node.clickable,
    editable: node.editable,
  };
  if (node.contentDescription !== undefined) copied.contentDescription = node.contentDescription;
  if (node.password === true) copied.password = true;
  return copied;
}
