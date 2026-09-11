/**
 * The four existing Ppomi Android MCP tools this adapter may call.
 * Names match `Ppomi/Sources/Ppomi/Serve/AndroidTools.swift`.
 * Not a device-approval, sign-in, payment, or Mac-approver surface.
 */
export type AndroidNativeToolName =
  | "android_open"
  | "android_screen"
  | "android_click"
  | "android_type";

/** Packages `android_open` accepts today (`AndroidTools.swift`). */
export const ANDROID_OPEN_PACKAGES = [
  "com.android.settings",
  "com.ppomi.androidtarget",
  "com.ppomi.androidbridge",
] as const;

export type AndroidOpenPackage = (typeof ANDROID_OPEN_PACKAGES)[number];

export interface AndroidScreenNode {
  readonly id: string;
  readonly text: string;
  readonly contentDescription?: string;
  readonly clickable: boolean;
  readonly editable: boolean;
  readonly password?: boolean;
}

export interface AndroidScreenRead {
  readonly snapshotId: string;
  readonly packageName: string;
  readonly appLabel: string;
  readonly nodes: readonly AndroidScreenNode[];
  readonly truncated: boolean;
}

export interface AndroidNativeTools {
  android_open(args: { packageName: string }): { opened: string };
  android_screen(): AndroidScreenRead;
  android_click(args: { nodeId: string }): { invoked: boolean };
  android_type(args: { nodeId: string; text: string }): { typed: boolean };
}

export class AndroidAdapterError extends Error {
  readonly code: string;

  constructor(code: string, message?: string) {
    super(message ?? code);
    this.name = "AndroidAdapterError";
    this.code = code;
  }
}

export function isAndroidOpenPackage(value: string): value is AndroidOpenPackage {
  return (ANDROID_OPEN_PACKAGES as readonly string[]).includes(value);
}
