/**
 * Mac tools this driver may call. Same AX-class names as `MacUI.swift` (PR #12)
 * and the Windows executor: `browser_open` / `screen_read` / `ui_tap` / `ui_type`.
 * Live Accessibility is `LiveMacosNativeTools` (System Events / AX). Tests use
 * `FixtureMacosNativeTools`. Not a device-approval or Mac-approver surface.
 */
export type MacNativeToolName = "browser_open" | "screen_read" | "ui_tap" | "ui_type";

/** Same 15s TTL as `MacUI.snapshotTTL`. */
export const MACOS_SNAPSHOT_TTL_MS = 15_000;

export interface MacScreenBounds {
  readonly left: number;
  readonly top: number;
  readonly right: number;
  readonly bottom: number;
}

export interface MacScreenNode {
  readonly id: string;
  readonly text: string;
  readonly clickable: boolean;
  readonly editable: boolean;
  readonly role?: string;
  readonly bounds?: MacScreenBounds;
}

export interface MacScreenRead {
  readonly snapshotId: string;
  readonly appLabel: string;
  readonly packageName?: string;
  readonly nodes: readonly MacScreenNode[];
  readonly truncated: boolean;
}

/** Shared with `Tools.isPayWord` — payment/purchase labels stay `protected_action`. */
export const MACOS_PAY_WORD = /(?<!바로)(결제|구매|주문|송금|이체|입금|충전|구독|가입)\s*(하기|완료|진행)?\s*$/;

export function isMacosPayWord(text: string): boolean {
  return MACOS_PAY_WORD.test(text.trim());
}

export function macosBrowserApp(raw: string): string | null {
  switch (raw.trim().toLowerCase()) {
    case "safari":
    case "com.apple.safari":
      return "Safari";
    case "chrome":
    case "google chrome":
    case "com.google.chrome":
      return "Google Chrome";
    default:
      return null;
  }
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
