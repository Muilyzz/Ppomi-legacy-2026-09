import type { OsUiDriver, ScreenSnapshot } from "./drivers.ts";
import type { PermissionGate } from "./permissions.ts";
import type { OsRef } from "./os-surface.ts";
import { OsSurface } from "./os-surface.ts";
import type { Playbook, PlaybookStep, RunResult } from "./playbook.ts";
import type { RuntimeOptions } from "./runtime-core.ts";
import { Runtime } from "./runtime-core.ts";

/**
 * OS-screen runner kept as a thin synchronous wrapper over `Runtime` so existing
 * adapters and call sites keep working. Legacy playbooks without `effect`
 * still execute here; a declared `commit` is handed off.
 * @deprecated Use `new Runtime(new OsSurface(adapter), permissions)` and declare `effect` on every mutation.
 */
export class PlaybookRuntime {
  private readonly core: Runtime<ScreenSnapshot, OsRef, PlaybookStep>;

  constructor(adapter: OsUiDriver, permissions: PermissionGate, options: RuntimeOptions = {}) {
    this.core = new Runtime(new OsSurface(adapter), permissions, { undeclaredMutations: "run", ...options });
  }

  run(playbook: Playbook): RunResult {
    return this.core.runSync(playbook);
  }
}
