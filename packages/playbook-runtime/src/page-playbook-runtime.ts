import type { BrowserPageAdapter, PageSnapshot } from "./browser-page-adapter.ts";
import { defaultPagePermission, type PermissionGate } from "./permissions.ts";
import type {
  PagePlaybook,
  PagePlaybookStep,
} from "./page-playbook.ts";
import type { RunResult, StepEvidence, StepOutcome } from "./playbook.ts";

/**
 * Runs declared in-page steps against one `BrowserPageAdapter`.
 * Authors: web DOM, forms, locator waits (`adapter-playwright`).
 * Native windows and cert UI use `PlaybookRuntime` + `OsAdapter`.
 * Do not `waitFor` a locator that only appears after a native modal.
 * See `docs/adapter-selection.md`.
 * Permission and page preconditions are fail-closed: the run stops
 * and later steps are not sent to the adapter.
 * Does not call `OsAdapter`. There is no device-approval input.
 */
export class PagePlaybookRuntime {
  private readonly adapter: BrowserPageAdapter;
  private readonly permissions: PermissionGate;

  constructor(adapter: BrowserPageAdapter, permissions: PermissionGate) {
    this.adapter = adapter;
    this.permissions = permissions;
  }

  run(playbook: PagePlaybook): RunResult {
    const evidence: StepEvidence[] = [];
    for (const step of playbook.steps) {
      const permission = step.require?.permission ?? defaultPagePermission(step.kind);
      if (!this.permissions.allows(permission)) {
        evidence.push(record(step, "permission_denied", [], `missing permission ${permission}`));
        return stop(evidence, "permission_denied");
      }

      const page = this.adapter.readPage();
      const why = unmetPrecondition(step, page);
      if (why !== null) {
        evidence.push(record(step, "precondition_failed", page.texts, why));
        return stop(evidence, "precondition_failed");
      }

      apply(this.adapter, step);
      evidence.push(record(step, "ok", page.texts, "step finished"));
    }
    return { status: "completed", stopReason: null, evidence };
  }
}

function apply(adapter: BrowserPageAdapter, step: PagePlaybookStep): void {
  switch (step.kind) {
    case "read":
      return;
    case "goto":
      adapter.goto(step.url!);
      return;
    case "click":
      adapter.click(step.locator!);
      return;
    case "fill":
      adapter.fill(step.locator!, step.text!);
      return;
    case "waitFor":
      adapter.waitFor(step.locator!);
      return;
    default: {
      const exhaustive: never = step.kind;
      throw new Error(`unhandled page step kind: ${String(exhaustive)}`);
    }
  }
}

function unmetPrecondition(step: PagePlaybookStep, page: PageSnapshot): string | null {
  if (step.require?.url !== undefined && page.url !== step.require.url) {
    return `url ${page.url} !== ${step.require.url}`;
  }

  const required = step.require?.texts ?? [];
  const missing = required.filter(text => !page.texts.includes(text));
  if (missing.length > 0) return `page missing ${missing.join(", ")}`;

  if (step.kind === "read") return null;

  if (step.kind === "goto") {
    if (step.url === undefined || step.url.length === 0) return "goto step url is required";
    return null;
  }

  if (step.locator === undefined || step.locator.length === 0) return "step locator is required";
  if (step.kind === "waitFor") return null;
  if (!page.locators.includes(step.locator)) return `locator not on page: ${step.locator}`;
  if (step.kind === "fill" && step.text === undefined) return "fill step text is required";
  return null;
}

function record(
  step: PagePlaybookStep,
  outcome: StepOutcome,
  pageTexts: readonly string[],
  note: string,
): StepEvidence {
  return { stepId: step.id, kind: step.kind, outcome, screenTexts: [...pageTexts], note };
}

function stop(evidence: StepEvidence[], stopReason: Exclude<StepOutcome, "ok">): RunResult {
  return { status: "stopped", stopReason, evidence };
}
