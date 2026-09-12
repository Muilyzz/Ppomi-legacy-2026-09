import type { OsUiDriver, ScreenSnapshot } from "../../ppomi-body/src/index.ts";
import type {
  IphoneMirroringTools,
  PhoneScreenRead,
  PhoneScreenRow,
} from "./iphone-mirroring-tools.ts";
import { IphoneMirroringAdapterError } from "./iphone-mirroring-tools.ts";

/** iPhone Mirroring Home: `phone key home` → ⌘1 → SpringBoard. Not Mac Home (keycode 115). */
export const IPHONE_HOME_KEY = "home";

/**
 * `OsUiDriver` over iPhone Mirroring `phone_*` tools on Mac.
 * Not on-device iOS AX. Not Mac desktop AX (`ppomi-body-macos`).
 */
export class IphoneMirroringDriver implements OsUiDriver {
  readonly kind = "phone" as const;
  private readonly tools: IphoneMirroringTools;
  private lastFocused: string | null = null;
  private lastScreen: PhoneScreenRead | null = null;

  constructor(tools: IphoneMirroringTools) {
    this.tools = tools;
  }

  readScreen(): ScreenSnapshot {
    this.lastScreen = this.tools.phone_screen();
    return toSnapshot(this.lastScreen, this.lastFocused);
  }

  focus(target: string): void {
    this.tools.phone_open({ app: target });
    this.lastFocused = target;
    this.lastScreen = null;
  }

  click(target: string): void {
    resolveRow(this.requireScreen(), target, "tappable");
    this.tools.phone_tap({ text: target });
    this.lastFocused = target;
    this.lastScreen = null;
  }

  type(target: string, text: string): void {
    resolveRow(this.requireScreen(), target, "editable");
    this.tools.phone_type({ text });
    this.lastFocused = target;
    this.lastScreen = null;
  }

  key(name: string): void {
    this.tools.phone_key({ name });
    this.lastScreen = null;
  }

  private requireScreen(): PhoneScreenRead {
    if (this.lastScreen !== null) return this.lastScreen;
    this.lastScreen = this.tools.phone_screen();
    return this.lastScreen;
  }
}

/** @deprecated Renamed to `IphoneMirroringDriver`. */
export const IphoneMirroringAdapter = IphoneMirroringDriver;

function toSnapshot(screen: PhoneScreenRead, lastFocused: string | null): ScreenSnapshot {
  const texts: string[] = [];
  addText(texts, screen.title);
  for (const row of screen.rows) addText(texts, row.text);
  return {
    title: screen.title,
    texts,
    focused: lastFocused,
  };
}

function addText(texts: string[], value: string): void {
  const text = value.trim();
  if (text.length === 0 || texts.includes(text)) return;
  texts.push(text);
}

function resolveRow(
  screen: PhoneScreenRead,
  target: string,
  need: "tappable" | "editable",
): PhoneScreenRow {
  const matches = screen.rows.filter(row => row.text === target);
  if (matches.length === 0) {
    throw new IphoneMirroringAdapterError("target_not_on_screen", `target not on screen: ${target}`);
  }
  const usable = matches.filter(row => (need === "tappable" ? row.tappable : row.editable));
  if (usable.length === 0) {
    throw new IphoneMirroringAdapterError("protected_action", `target not ${need}: ${target}`);
  }
  if (usable.length !== 1) {
    throw new IphoneMirroringAdapterError("ambiguous_target", `ambiguous target: ${target}`);
  }
  return usable[0]!;
}
