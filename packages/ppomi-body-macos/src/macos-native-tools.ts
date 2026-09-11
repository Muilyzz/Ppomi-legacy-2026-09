/**
 * Mac tools this adapter may call.
 * `browser_open` exists in Swift MCP (`Tools.browser_open` / `MacBrowser.open`).
 * `screen_read` / `ui_tap` / `ui_type` are the same AX-class names as the Windows
 * executor and Android voice bridge; Mac MCP does not expose them yet.
 * Not a device-approval, sign-in, or Mac-approver surface.
 */
export type MacNativeToolName = "browser_open" | "screen_read" | "ui_tap" | "ui_type";

export interface MacScreenNode {
  readonly id: string;
  readonly text: string;
  readonly clickable: boolean;
  readonly editable: boolean;
}

export interface MacScreenRead {
  readonly snapshotId: string;
  readonly appLabel: string;
  readonly nodes: readonly MacScreenNode[];
  readonly truncated: boolean;
}

export interface MacNativeTools {
  browser_open(args: { app?: string; url?: string }): { opened: boolean; app: string };
  screen_read(): MacScreenRead;
  ui_tap(args: { nodeId: string }): { invoked: boolean };
  ui_type(args: { nodeId: string; text: string }): { typed: boolean };
}

export class MacosAdapterError extends Error {
  readonly code: string;

  constructor(code: string, message?: string) {
    super(message ?? code);
    this.name = "MacosAdapterError";
    this.code = code;
  }
}
