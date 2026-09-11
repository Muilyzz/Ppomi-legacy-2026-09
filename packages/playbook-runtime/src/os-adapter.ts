/** Native / system-chrome / iPhone-Mirroring port (`PlaybookRuntime`). Not in-page DOM. See `docs/adapter-selection.md`. No device-approval input. */
export interface ScreenSnapshot {
  readonly title: string;
  readonly texts: readonly string[];
  readonly focused: string | null;
}

export interface OsAdapter {
  readScreen(): ScreenSnapshot;
  focus(target: string): void;
  click(target: string): void;
  type(target: string, text: string): void;
}
