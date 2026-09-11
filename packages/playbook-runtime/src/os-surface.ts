import type { OsAdapter, ScreenSnapshot } from "./os-adapter.ts";
import { defaultPermission } from "./permissions.ts";
import type { PlaybookStep } from "./playbook.ts";
import type { Resolution, StepClass, Surface } from "./runtime-core.ts";
import type { RuntimeCode } from "./step-result.ts";

export type OsRef =
  | { readonly kind: "read" }
  | { readonly kind: "focus"; readonly target: string }
  | { readonly kind: "click"; readonly target: string }
  | { readonly kind: "type"; readonly target: string; readonly text: string };

/** The OS screen as a runtime surface: screen-text targets over one `OsAdapter`. */
export class OsSurface implements Surface<ScreenSnapshot, OsRef, PlaybookStep> {
  readonly kind = "os" as const;
  private readonly adapter: OsAdapter;

  constructor(adapter: OsAdapter) {
    this.adapter = adapter;
  }

  async read(): Promise<ScreenSnapshot> {
    return await this.adapter.readScreen();
  }

  observed(snap: ScreenSnapshot): readonly string[] {
    return snap.texts;
  }

  location(): string | null {
    return null;
  }

  classify(step: PlaybookStep): StepClass {
    return { permission: defaultPermission(step.kind), mutation: step.kind !== "read" };
  }

  resolve(snap: ScreenSnapshot, step: PlaybookStep): Resolution<OsRef> {
    const required = step.require?.screen ?? [];
    const missing = required.filter(text => !snap.texts.includes(text));
    if (missing.length > 0) return unmet("screen_missing", `screen missing ${missing.join(", ")}`);

    if (step.require?.focused !== undefined && snap.focused !== step.require.focused) {
      return unmet("focus_mismatch", `focused ${snap.focused ?? "(none)"} !== ${step.require.focused}`);
    }

    switch (step.kind) {
      case "read":
        return { ok: true, ref: { kind: "read" } };
      case "focus":
      case "click": {
        const target = step.target;
        if (target === undefined || target.length === 0) return unmet("target_required", "step target is required");
        if (!onScreen(snap, target)) return unmet("target_not_on_screen", `target not on screen: ${target}`);
        return { ok: true, ref: { kind: step.kind, target } };
      }
      case "type": {
        const target = step.target;
        if (target === undefined || target.length === 0) return unmet("target_required", "step target is required");
        if (!onScreen(snap, target)) return unmet("target_not_on_screen", `target not on screen: ${target}`);
        if (step.text === undefined) return unmet("text_required", "type step text is required");
        return { ok: true, ref: { kind: "type", target, text: step.text } };
      }
      default: {
        const exhaustive: never = step.kind;
        throw new Error(`unhandled step kind: ${String(exhaustive)}`);
      }
    }
  }

  async act(_step: PlaybookStep, ref: OsRef): Promise<void> {
    switch (ref.kind) {
      case "read":
        return;
      case "focus":
        await this.adapter.focus(ref.target);
        return;
      case "click":
        await this.adapter.click(ref.target);
        return;
      case "type":
        await this.adapter.type(ref.target, ref.text);
        return;
      default: {
        const exhaustive: never = ref;
        throw new Error(`unhandled ref: ${String(exhaustive)}`);
      }
    }
  }
}

function onScreen(snap: ScreenSnapshot, target: string): boolean {
  return snap.focused === target || snap.texts.includes(target);
}

function unmet(code: RuntimeCode, detail: string): Resolution<never> {
  return { ok: false, code, detail };
}
