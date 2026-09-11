import type { BrowserPageDriver } from "./drivers.ts";
import type { PagePlaybook } from "./page-playbook.ts";
import { PageSurface } from "./page-surface.ts";
import type { PermissionGate } from "./permissions.ts";
import type { RunResult } from "./playbook.ts";
import type { LegacyOptions, RuntimeOptions } from "./runtime-core.ts";
import { Runtime } from "./runtime-core.ts";

/** Page runs are always `driver: "page"`; there is nothing to override. */
export interface PagePlaybookRuntimeOptions extends Omit<RuntimeOptions, "driver"> {
  /** Execute mutations without a declared `effect`, marked `undeclared_effect` and `legacy: true`. Deleted with the wrapper. */
  readonly legacy?: LegacyOptions;
}

/**
 * In-page runner kept as a thin synchronous wrapper over `Runtime` so existing
 * ports and call sites keep compiling. Like `Runtime`, it hands off mutations
 * without a declared `effect`; only `legacy.runUndeclaredMutations` runs them.
 * The playbook's `allowedOrigins` bind the surface.
 * @deprecated Use `new Runtime(new PageSurface(port, allowedOrigins), permissions)` and declare `effect` on every mutation.
 */
export class PagePlaybookRuntime {
  private readonly port: BrowserPageDriver;
  private readonly permissions: PermissionGate;
  private readonly options: RuntimeOptions;
  private readonly legacy: LegacyOptions | undefined;

  constructor(port: BrowserPageDriver, permissions: PermissionGate, options: PagePlaybookRuntimeOptions = {}) {
    const { legacy, ...runtimeOptions } = options;
    this.port = port;
    this.permissions = permissions;
    this.options = runtimeOptions;
    this.legacy = legacy;
  }

  run(playbook: PagePlaybook): RunResult {
    const surface = new PageSurface(this.port, playbook.allowedOrigins);
    return new Runtime(surface, this.permissions, this.options).runSync(playbook, this.legacy);
  }
}
