import type { OsAdapter, ScreenSnapshot } from "./os-adapter.ts";
import type { PermissionGate } from "./permissions.ts";
import type { OsRef } from "./os-surface.ts";
import { OsSurface } from "./os-surface.ts";
import type { Playbook, PlaybookStep } from "./playbook.ts";
import type { RunResult } from "./step-result.ts";
import type { RuntimeOptions } from "./runtime-core.ts";
import { Runtime } from "./runtime-core.ts";

/**
 * OS-screen runner kept as a thin wrapper so existing adapters and call sites
 * compile; `run` is async now.
 * @deprecated Use `new Runtime(new OsSurface(adapter), permissions)`.
 */
export class PlaybookRuntime {
  private readonly core: Runtime<ScreenSnapshot, OsRef, PlaybookStep>;

  constructor(adapter: OsAdapter, permissions: PermissionGate, options: RuntimeOptions = {}) {
    this.core = new Runtime(new OsSurface(adapter), permissions, options);
  }

  run(playbook: Playbook): Promise<RunResult> {
    return this.core.run(playbook);
  }
}
