import type { BrowserPageAdapter } from "./browser-page-adapter.ts";
import type { PagePlaybook } from "./page-playbook.ts";
import { PageSurface } from "./page-surface.ts";
import type { PermissionGate } from "./permissions.ts";
import type { RunResult } from "./step-result.ts";
import type { RuntimeOptions } from "./runtime-core.ts";
import { Runtime } from "./runtime-core.ts";

/**
 * In-page runner kept as a thin wrapper so existing adapters and call sites
 * compile; `run` is async now. The playbook's `allowedOrigins` bind the surface.
 * @deprecated Use `new Runtime(new PageSurface(adapter, allowedOrigins), permissions)`.
 */
export class PagePlaybookRuntime {
  private readonly adapter: BrowserPageAdapter;
  private readonly permissions: PermissionGate;
  private readonly options: RuntimeOptions;

  constructor(adapter: BrowserPageAdapter, permissions: PermissionGate, options: RuntimeOptions = {}) {
    this.adapter = adapter;
    this.permissions = permissions;
    this.options = options;
  }

  run(playbook: PagePlaybook): Promise<RunResult> {
    const surface = new PageSurface(this.adapter, playbook.allowedOrigins);
    return new Runtime(surface, this.permissions, this.options).run(playbook);
  }
}
