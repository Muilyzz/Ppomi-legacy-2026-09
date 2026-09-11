/** Minimal OS port. Slice 2 implements this as `adapter-windows`; this package ships a dummy. */
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
