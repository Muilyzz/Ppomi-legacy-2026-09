import type { BrowserPageDriver } from "./drivers.ts";
import type { PagePlaybook } from "./page-playbook.ts";
import { PageSurface } from "./page-surface.ts";
import type { PermissionGate } from "./permissions.ts";
import type { RunResult } from "./playbook.ts";
import type { RuntimeOptions } from "./runtime-core.ts";
import { Runtime } from "./runtime-core.ts";

/** Page runs are always `driver: "page"`; there is nothing to override. */
export type PagePlaybookRuntimeOptions = Omit<RuntimeOptions, "driver">;

/**
 * In-page runner kept as a thin synchronous wrapper over `Runtime` so existing
 * ports and call sites keep compiling. Legacy playbooks without `effect` still
 * execute here; a declared `commit` is handed off. The playbook's
 * `allowedOrigins` bind the surface.
 * @deprecated Use `new Runtime(new PageSurface(port, allowedOrigins), permissions)` and declare `effect` on every mutation.
 */
export class PagePlaybookRuntime {
  private readonly port: BrowserPageDriver;
  private readonly permissions: PermissionGate;
  private readonly options: RuntimeOptions;

  constructor(port: BrowserPageDriver, permissions: PermissionGate, options: PagePlaybookRuntimeOptions = {}) {
    this.port = port;
    this.permissions = permissions;
    this.options = { undeclaredMutations: "run", ...options };
  }

  run(playbook: PagePlaybook): RunResult {
    const surface = new PageSurface(this.port, playbook.allowedOrigins);
    return new Runtime(surface, this.permissions, this.options).runSync(playbook);
  }
}
