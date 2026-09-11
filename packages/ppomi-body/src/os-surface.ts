import type { OsUiDriver, ScreenSnapshot } from "./drivers.ts";
import { defaultPermission } from "./permissions.ts";
import type { MaybePromise, PlaybookStep } from "./playbook.ts";
import type { RuntimeCode } from "./emit-step-result.ts";
import type { Resolution, StepClass, UiDriver } from "./runtime-core.ts";
import type { StepDriver, StepTarget } from "./step-result.ts";

export type OsRef =
  | { readonly kind: "read" }
  | { readonly kind: "focus"; readonly target: string }
  | { readonly kind: "click"; readonly target: string }
  | { readonly kind: "type"; readonly target: string; readonly text: string }
  | { readonly kind: "key"; readonly name: string };

/** The OS screen as a `UiDriver`: screen-text targets over one `OsUiDriver` port. */
export class OsSurface implements UiDriver<ScreenSnapshot, OsRef, PlaybookStep> {
  readonly driver: StepDriver | undefined;
  private readonly os: OsUiDriver;

  constructor(port: OsUiDriver) {
    this.os = port;
    this.driver = port.kind;
  }

  read(): MaybePromise<ScreenSnapshot> {
    return this.os.readScreen();
  }

  observed(snap: ScreenSnapshot): readonly string[] {
    return snap.texts;
  }

  /** Screen text is the OS accessible name; node ids and coordinates never enter a result. */
  target(step: PlaybookStep): StepTarget {
    if (step.kind === "key") return { kind: "none" };
    return step.target !== undefined && step.target.length > 0
      ? { kind: "accessibility", name: step.target }
      : { kind: "none" };
  }

  /**
   * `focus` only foregrounds an already-running app by its accessible name: it needs
   * `ui.control` but has an implied `navigate` effect and is never gated. It is never
   * `browser_open({ url })` or an app launch.
   */
  classify(step: PlaybookStep): StepClass {
    return {
      permission: defaultPermission(step.kind),
      mutation: step.kind === "click" || step.kind === "type" || step.kind === "key",
    };
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
      case "key": {
        const name = step.target;
        if (name === undefined || name.length === 0) return unmet("target_required", "step target is required");
        if (this.os.key === undefined) return unmet("target_required", "driver has no key");
        return { ok: true, ref: { kind: "key", name } };
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
      case "key": {
        const send = this.os.key;
        if (send === undefined) throw new Error("driver has no key");
        return send.call(this.os, ref.name);
      }
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
