/** Native / system-chrome port (`PlaybookRuntime`). Not in-page DOM. See `docs/adapter-selection.md`. No device-approval input. */
export type OsAdapterKind = "os-windows" | "os-macos" | "phone";

export interface ScreenSnapshot {
  readonly title: string;
  readonly texts: readonly string[];
  readonly focused: string | null;
}

export interface OsAdapter {
  readonly kind: OsAdapterKind;
  readScreen(): ScreenSnapshot;
  focus(target: string): void;
  click(target: string): void;
  type(target: string, text: string): void;
}
