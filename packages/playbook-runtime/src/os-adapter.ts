import type { MaybePromise } from "./playbook.ts";

/**
 * Native / system-chrome port (`OsSurface`). OS packages (`adapter-windows`,
 * `adapter-macos`) implement it; this package ships a dummy. Sync adapters still
 * satisfy it: the runtime awaits every call. No device-approval input.
 */
export interface ScreenSnapshot {
  readonly title: string;
  readonly texts: readonly string[];
  readonly focused: string | null;
}

export interface OsAdapter {
  readScreen(): MaybePromise<ScreenSnapshot>;
  focus(target: string): MaybePromise<void>;
  click(target: string): MaybePromise<void>;
  type(target: string, text: string): MaybePromise<void>;
}
