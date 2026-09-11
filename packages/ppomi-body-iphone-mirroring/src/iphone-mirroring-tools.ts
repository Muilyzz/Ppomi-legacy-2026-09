/**
 * Existing MCP `phone_*` tools this adapter may call.
 * They drive the **iPhone Mirroring** window on Mac (`com.apple.ScreenContinuity`),
 * not on-device iOS Accessibility and not Mac desktop AX (`adapter-macos`).
 * Not a device-approval, sign-in, or Mac-approver surface.
 */
export type IphoneMirroringToolName =
  | "phone_screen"
  | "phone_tap"
  | "phone_type"
  | "phone_key"
  | "phone_scroll"
  | "phone_open";

export interface PhoneScreenRow {
  readonly text: string;
  readonly tappable: boolean;
  readonly editable: boolean;
}

export interface PhoneScreenRead {
  readonly title: string;
  readonly rows: readonly PhoneScreenRow[];
}

export interface IphoneMirroringTools {
  phone_screen(): PhoneScreenRead;
  phone_tap(args: { text?: string; x?: number; y?: number }): { tapped: boolean };
  phone_type(args: { text: string }): { typed: boolean };
  phone_key(args: { name: string }): { sent: boolean };
  phone_scroll(args: { dy: number; y?: number }): { scrolled: boolean };
  phone_open(args: { app?: string; title?: string; search?: string }): { opened: boolean; app: string };
}

export class IphoneMirroringAdapterError extends Error {
  readonly code: string;

  constructor(code: string, message?: string) {
    super(message ?? code);
    this.name = "IphoneMirroringAdapterError";
    this.code = code;
  }
}
