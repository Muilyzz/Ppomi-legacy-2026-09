import type { OsAdapter, OsAdapterKind, ScreenSnapshot } from "./os-adapter.ts";

export type DummyCall =
  | { readonly kind: "read" }
  | { readonly kind: "focus"; readonly target: string }
  | { readonly kind: "click"; readonly target: string }
  | { readonly kind: "type"; readonly target: string; readonly text: string };

/** In-memory adapter for unit tests. Not `adapter-windows`. */
export class DummyAdapter implements OsAdapter {
  readonly kind: OsAdapterKind;
  readonly calls: DummyCall[] = [];
  private screen: ScreenSnapshot;

  constructor(screen: ScreenSnapshot, kind: OsAdapterKind = "os-windows") {
    this.kind = kind;
    this.screen = copyScreen(screen);
  }

  setScreen(screen: ScreenSnapshot): void {
    this.screen = copyScreen(screen);
  }

  readScreen(): ScreenSnapshot {
    this.calls.push({ kind: "read" });
    return copyScreen(this.screen);
  }

  focus(target: string): void {
    this.assertPresent(target, "focus");
    this.calls.push({ kind: "focus", target });
    this.screen = { ...this.screen, focused: target };
  }

  click(target: string): void {
    this.assertPresent(target, "click");
    this.calls.push({ kind: "click", target });
    this.screen = { ...this.screen, focused: target };
  }

  type(target: string, text: string): void {
    this.assertPresent(target, "type");
    this.calls.push({ kind: "type", target, text });
    this.screen = { ...this.screen, focused: target };
  }

  private assertPresent(target: string, action: "focus" | "click" | "type"): void {
    if (this.screen.focused === target || this.screen.texts.includes(target)) return;
    throw new Error(`dummy adapter refused ${action}: target not on screen`);
  }
}

function copyScreen(screen: ScreenSnapshot): ScreenSnapshot {
  return {
    title: screen.title,
    texts: [...screen.texts],
    focused: screen.focused,
  };
}
