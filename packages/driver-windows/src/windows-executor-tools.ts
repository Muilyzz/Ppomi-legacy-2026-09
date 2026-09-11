/**
 * The four `executors/windows` tools this adapter may call.
 * Not a device-approval, sign-in, or Mac-approver surface.
 *
 * Contracts below were measured against the real `ppomi-executor` (Windows 11 ARM64, Edge target):
 * - `screen_read` returns a fresh `snapshotId`; every `nodeId` is `"<snapshotId>:<index>"`.
 * - Only the latest snapshot is addressable, and it expires after {@link WINDOWS_SNAPSHOT_TTL_MS}.
 * - `ui_tap` / `ui_type` answer `requiresScreenRead: true`: the caller must `screen_read` again
 *   before the next addressed action. Executor error codes are passed through unchanged.
 */
export type WindowsExecutorToolName = "app_open" | "screen_read" | "ui_tap" | "ui_type";

/** Measured executor snapshot lifetime; an older read is rejected with `stale_screen`. */
export const WINDOWS_SNAPSHOT_TTL_MS = 15_000;

export interface WindowsScreenNode {
  readonly id: string;
  readonly text: string;
  readonly clickable: boolean;
  readonly editable: boolean;
  /** UIA control type as reported by the executor, e.g. `"ControlType.Edit"`. Fixtures may omit it. */
  readonly role?: string;
}

export interface WindowsScreenRead {
  readonly snapshotId: string;
  readonly packageName: string;
  readonly appLabel: string;
  readonly nodes: readonly WindowsScreenNode[];
  readonly truncated: boolean;
}

/** Every addressed mutation invalidates the snapshot it was addressed against. */
export interface WindowsActionResult {
  readonly requiresScreenRead: boolean;
}

export interface WindowsExecutorTools {
  app_open(args: { target: string }): { packageName: string; activated: boolean };
  screen_read(): WindowsScreenRead;
  ui_tap(args: { nodeId: string }): WindowsActionResult & { invoked: boolean };
  ui_type(args: { nodeId: string; text: string }): WindowsActionResult & { typed: boolean };
}

/** `"<snapshotId>:<index>"` → `"<snapshotId>"`, or `null` when the id is not in that shape. */
export function snapshotIdOf(nodeId: string): string | null {
  const separator = nodeId.lastIndexOf(":");
  if (separator <= 0 || separator === nodeId.length - 1) return null;
  return nodeId.slice(0, separator);
}

export class WindowsAdapterError extends Error {
  readonly code: string;

  constructor(code: string, message?: string) {
    super(message ?? code);
    this.name = "WindowsAdapterError";
    this.code = code;
  }
}
