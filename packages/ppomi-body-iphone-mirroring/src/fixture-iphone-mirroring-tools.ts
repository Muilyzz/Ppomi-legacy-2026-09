import type {
  IphoneMirroringToolName,
  IphoneMirroringTools,
  PhoneScreenRead,
  PhoneScreenRow,
} from "./iphone-mirroring-tools.ts";
import { IphoneMirroringAdapterError } from "./iphone-mirroring-tools.ts";

export interface FixtureIphoneMirroringScreen {
  readonly appLabel: string;
  readonly rows: readonly PhoneScreenRow[];
}

export type FixtureIphoneMirroringCall =
  | { readonly name: "phone_screen"; readonly args: Record<string, never> }
  | { readonly name: "phone_tap"; readonly args: { readonly text?: string; readonly x?: number; readonly y?: number } }
  | { readonly name: "phone_type"; readonly args: { readonly text: string } }
  | { readonly name: "phone_key"; readonly args: { readonly name: string } }
  | { readonly name: "phone_scroll"; readonly args: { readonly dy: number; readonly y?: number } }
  | {
      readonly name: "phone_open";
      readonly args: { readonly app?: string; readonly title?: string; readonly search?: string };
    };

/** In-memory stand-in for iPhone Mirroring `phone_*` tools. No live mirroring, no iOS AX. */
export class FixtureIphoneMirroringTools implements IphoneMirroringTools {
  readonly calls: FixtureIphoneMirroringCall[] = [];
  private readonly screen: FixtureIphoneMirroringScreen;

  constructor(screen: FixtureIphoneMirroringScreen) {
    this.screen = screen;
  }

  phone_screen(): PhoneScreenRead {
    this.calls.push({ name: "phone_screen", args: {} });
    return {
      title: this.screen.appLabel,
      rows: this.screen.rows.map(row => ({ ...row })),
    };
  }

  phone_tap(args: { text?: string; x?: number; y?: number }): { tapped: boolean } {
    this.calls.push({ name: "phone_tap", args: copyTapArgs(args) });
    if (args.text === undefined) {
      throw new IphoneMirroringAdapterError("text_required", "phone_tap needs observation text, not coordinates");
    }
    const row = this.screen.rows.find(item => item.text === args.text);
    if (row === undefined || !row.tappable) {
      throw new IphoneMirroringAdapterError("stale_screen", `target not tappable: ${args.text}`);
    }
    return { tapped: true };
  }

  phone_type(args: { text: string }): { typed: boolean } {
    this.calls.push({ name: "phone_type", args: { text: args.text } });
    if (!this.screen.rows.some(row => row.editable)) {
      throw new IphoneMirroringAdapterError("stale_screen", "no editable row on mirrored screen");
    }
    return { typed: true };
  }

  phone_key(args: { name: string }): { sent: boolean } {
    this.calls.push({ name: "phone_key", args: { name: args.name } });
    return { sent: true };
  }

  phone_scroll(args: { dy: number; y?: number }): { scrolled: boolean } {
    this.calls.push({ name: "phone_scroll", args: copyScrollArgs(args) });
    return { scrolled: true };
  }

  phone_open(args: { app?: string; title?: string; search?: string }): { opened: boolean; app: string } {
    this.calls.push({ name: "phone_open", args: copyOpenArgs(args) });
    const requested = args.app ?? args.title;
    if (requested !== this.screen.appLabel) {
      throw new IphoneMirroringAdapterError("app_not_found", `app not on fixture: ${requested ?? "(none)"}`);
    }
    return { opened: true, app: this.screen.appLabel };
  }
}

export function fixtureToolNames(calls: readonly FixtureIphoneMirroringCall[]): IphoneMirroringToolName[] {
  return calls.map(call => call.name);
}

function copyOpenArgs(args: {
  app?: string;
  title?: string;
  search?: string;
}): { app?: string; title?: string; search?: string } {
  const copied: { app?: string; title?: string; search?: string } = {};
  if (args.app !== undefined) copied.app = args.app;
  if (args.title !== undefined) copied.title = args.title;
  if (args.search !== undefined) copied.search = args.search;
  return copied;
}

function copyTapArgs(args: { text?: string; x?: number; y?: number }): {
  text?: string;
  x?: number;
  y?: number;
} {
  const copied: { text?: string; x?: number; y?: number } = {};
  if (args.text !== undefined) copied.text = args.text;
  if (args.x !== undefined) copied.x = args.x;
  if (args.y !== undefined) copied.y = args.y;
  return copied;
}

function copyScrollArgs(args: { dy: number; y?: number }): { dy: number; y?: number } {
  const copied: { dy: number; y?: number } = { dy: args.dy };
  if (args.y !== undefined) copied.y = args.y;
  return copied;
}
