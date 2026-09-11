/**
 * The four `executors/windows` tools this adapter may call.
 * Not a device-approval, sign-in, or Mac-approver surface.
 */
export type WindowsExecutorToolName = "app_open" | "screen_read" | "ui_tap" | "ui_type";

export interface WindowsScreenNode {
  readonly id: string;
  readonly text: string;
  readonly clickable: boolean;
  readonly editable: boolean;
}

export interface WindowsScreenRead {
  readonly snapshotId: string;
  readonly packageName: string;
  readonly appLabel: string;
  readonly nodes: readonly WindowsScreenNode[];
  readonly truncated: boolean;
}

export interface WindowsExecutorTools {
  app_open(args: { target: string }): { packageName: string; activated: boolean };
  screen_read(): WindowsScreenRead;
  ui_tap(args: { nodeId: string }): { invoked: boolean };
  ui_type(args: { nodeId: string; text: string }): { typed: boolean };
}

export class WindowsAdapterError extends Error {
  readonly code: string;

  constructor(code: string, message?: string) {
    super(message ?? code);
    this.name = "WindowsAdapterError";
    this.code = code;
  }
}
