import type { OsUiDriver, OsUiDriverKind, ScreenSnapshot } from "./drivers.ts";
import type { PermissionGate } from "./permissions.ts";
import type { OsRef } from "./os-surface.ts";
import { OsSurface } from "./os-surface.ts";
import type { Playbook, PlaybookStep, RunResult } from "./playbook.ts";
import type { RuntimeOptions } from "./runtime-core.ts";
import { Runtime } from "./runtime-core.ts";

export interface PlaybookRuntimeOptions extends Omit<RuntimeOptions, "driver"> {
  /**
   * Which OS family the port controls when it does not declare `kind` itself.
   * There is no silent default: without either, every run is `invalid` (`unknown_driver`).
   */
  readonly driver?: OsUiDriverKind;
}

/**
 * OS-screen runner kept as a thin synchronous wrapper over `Runtime` so existing
 * ports and call sites keep compiling. Legacy playbooks without `effect` still
 * execute here; a declared `commit` is handed off.
 * @deprecated Use `new Runtime(new OsSurface(port), permissions)` and declare `effect` on every mutation.
 */
export class PlaybookRuntime {
  private readonly core: Runtime<ScreenSnapshot, OsRef, PlaybookStep>;

  constructor(port: OsUiDriver, permissions: PermissionGate, options: PlaybookRuntimeOptions = {}) {
    this.core = new Runtime(new OsSurface(port), permissions, { undeclaredMutations: "run", ...options });
  }

  run(playbook: Playbook): RunResult {
    return this.core.runSync(playbook);
  }
}
