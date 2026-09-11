import type { OsUiDriver, OsUiDriverKind, ScreenSnapshot } from "./drivers.ts";
import type { PermissionGate } from "./permissions.ts";
import type { OsRef } from "./os-surface.ts";
import { OsSurface } from "./os-surface.ts";
import type { Playbook, PlaybookStep, RunResult } from "./playbook.ts";
import type { LegacyOptions, RuntimeOptions } from "./runtime-core.ts";
import { Runtime } from "./runtime-core.ts";

export interface PlaybookRuntimeOptions extends Omit<RuntimeOptions, "driver"> {
  /**
   * Which OS family the port controls when it does not declare `kind` itself.
   * There is no silent default: without either, every run is `invalid` (`unknown_driver`).
   */
  readonly driver?: OsUiDriverKind;
  /** Execute mutations without a declared `effect`, marked `undeclared_effect` and `legacy: true`. Deleted with the wrapper. */
  readonly legacy?: LegacyOptions;
}

/**
 * OS-screen runner kept as a thin synchronous wrapper over `Runtime` so existing
 * ports and call sites keep compiling. Like `Runtime`, it hands off mutations
 * without a declared `effect`; only `legacy.runUndeclaredMutations` runs them.
 * @deprecated Use `new Runtime(new OsSurface(port), permissions)` and declare `effect` on every mutation.
 */
export class PlaybookRuntime {
  private readonly core: Runtime<ScreenSnapshot, OsRef, PlaybookStep>;
  private readonly legacy: LegacyOptions | undefined;

  constructor(port: OsUiDriver, permissions: PermissionGate, options: PlaybookRuntimeOptions = {}) {
    const { legacy, ...runtimeOptions } = options;
    this.legacy = legacy;
    this.core = new Runtime(new OsSurface(port), permissions, runtimeOptions);
  }

  run(playbook: Playbook): RunResult {
    return this.core.runSync(playbook, this.legacy);
  }
}
