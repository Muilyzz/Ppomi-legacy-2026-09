/** Minimal OS port. OS packages (`adapter-windows`, `adapter-macos`) implement this; this package ships a dummy. No device-approval input. */
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
