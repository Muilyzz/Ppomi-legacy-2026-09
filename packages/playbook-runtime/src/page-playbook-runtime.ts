import type { BrowserPageAdapter } from "./browser-page-adapter.ts";
import type { PagePlaybook } from "./page-playbook.ts";
import { PageSurface } from "./page-surface.ts";
import type { PermissionGate } from "./permissions.ts";
import type { RunResult } from "./playbook.ts";
import type { RuntimeOptions } from "./runtime-core.ts";
import { Runtime } from "./runtime-core.ts";

/**
 * In-page runner kept as a thin synchronous wrapper over `Runtime` so existing
 * adapters and call sites keep working. Legacy playbooks without `effect`
 * still execute here; a declared `commit` is handed off. The playbook's
 * `allowedOrigins` bind the surface.
 * @deprecated Use `new Runtime(new PageSurface(adapter, allowedOrigins), permissions)` and declare `effect` on every mutation.
 */
export class PagePlaybookRuntime {
  private readonly adapter: BrowserPageAdapter;
  private readonly permissions: PermissionGate;
  private readonly options: RuntimeOptions;

  constructor(adapter: BrowserPageAdapter, permissions: PermissionGate, options: RuntimeOptions = {}) {
    this.adapter = adapter;
    this.permissions = permissions;
    this.options = { undeclaredMutations: "run", ...options };
  }

  run(playbook: PagePlaybook): RunResult {
    const surface = new PageSurface(this.adapter, playbook.allowedOrigins);
    return new Runtime(surface, this.permissions, this.options).runSync(playbook);
  }
}
