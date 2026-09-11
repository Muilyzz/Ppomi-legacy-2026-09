import type { OsUiDriver, ScreenSnapshot } from "./drivers.ts";
import { defaultPermission } from "./permissions.ts";
import type { MaybePromise, PlaybookStep } from "./playbook.ts";
import type { Resolution, RuntimeCode, StepClass, UiDriver } from "./runtime-core.ts";
import type { StepAdapter, StepTarget } from "./step-result.ts";

export type OsRef =
  | { readonly kind: "read" }
  | { readonly kind: "focus"; readonly target: string }
  | { readonly kind: "click"; readonly target: string }
  | { readonly kind: "type"; readonly target: string; readonly text: string };

/** The OS screen as a runtime surface: screen-text targets over one `OsUiDriver`. */
export class OsSurface implements UiDriver<ScreenSnapshot, OsRef, PlaybookStep> {
  readonly surface = "os" as const;
  readonly adapter: StepAdapter;
  private readonly os: OsUiDriver;

  constructor(adapter: OsUiDriver) {
    this.os = adapter;
    this.adapter = adapter.kind;
  }

  read(): MaybePromise<ScreenSnapshot> {
    return this.os.readScreen();
  }

  observed(snap: ScreenSnapshot): readonly string[] {
    return snap.texts;
  }

  /** Screen text is the OS accessible name; node ids and coordinates never enter a result. */
  target(step: PlaybookStep): StepTarget {
    return step.target !== undefined && step.target.length > 0
      ? { kind: "accessibility", name: step.target }
      : { kind: "none" };
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

  act(_step: PlaybookStep, ref: OsRef): MaybePromise<void> {
    switch (ref.kind) {
      case "read":
        return undefined;
      case "focus":
        return this.os.focus(ref.target);
      case "click":
        return this.os.click(ref.target);
      case "type":
        return this.os.type(ref.target, ref.text);
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
