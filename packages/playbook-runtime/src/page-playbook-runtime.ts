import { isAdapterTimeout } from "./adapter-timeout.ts";
import type { BrowserPageAdapter, PageSnapshot } from "./browser-page-adapter.ts";
import { emitNotExecutedRest, emitStepResult } from "./emit-step-result.ts";
import { defaultPagePermission, type PermissionGate } from "./permissions.ts";
import type {
  PagePlaybook,
  PagePlaybookStep,
} from "./page-playbook.ts";
import type { RunResult, StepEvidence, StepOutcome } from "./playbook.ts";
import type { StepResult, StepTarget } from "./step-result.ts";

/**
 * Runs declared in-page steps against one `BrowserPageAdapter`.
 * Authors: web DOM, forms, locator waits (`adapter-playwright`).
 * Native windows and cert UI use `PlaybookRuntime` + `OsAdapter`.
 * Do not `waitFor` a locator that only appears after a native modal.
 * See `docs/adapter-selection.md`.
 * Permission and page preconditions are fail-closed: the run stops
 * and later steps are not sent to the adapter.
 * `RunResult.evidence` is the runner log. `RunResult.stepResults` is
 * one `StepResult` per declared step (`attempt` distinguishes timeout
 * from not_executed). Does not call `OsAdapter`. There is no
 * device-approval input.
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
    const stepResults: StepResult[] = [];
    for (let index = 0; index < playbook.steps.length; index += 1) {
      const step = playbook.steps[index]!;
      const permission = step.require?.permission ?? defaultPagePermission(step.kind);
      if (!this.permissions.allows(permission)) {
        const note = `missing permission ${permission}`;
        evidence.push(record(step, "permission_denied", [], note));
        stepResults.push(pageStepResult(playbook.id, step, "protected", "not_executed", note, 0));
        return stop(
          evidence,
          stepResults.concat(rest(playbook, index + 1)),
          "permission_denied",
        );
      }

      const page = this.adapter.readPage();
      const why = unmetPrecondition(step, page);
      if (why !== null) {
        evidence.push(record(step, "precondition_failed", page.texts, why));
        stepResults.push(pageStepResult(playbook.id, step, "failed", "not_executed", why, 0));
        return stop(
          evidence,
          stepResults.concat(rest(playbook, index + 1)),
          "precondition_failed",
        );
      }

      const started = Date.now();
      try {
        apply(this.adapter, step);
      } catch (error) {
        const timingMs = Date.now() - started;
        const timeout = isAdapterTimeout(error);
        const note = error instanceof Error ? error.message : String(error);
        const outcome: Exclude<StepOutcome, "ok"> = timeout ? "timeout" : "failed";
        evidence.push(record(step, outcome, page.texts, note));
        stepResults.push(pageStepResult(
          playbook.id,
          step,
          timeout ? "retryable" : "failed",
          timeout ? "timeout" : "executed",
          note,
          timingMs,
        ));
        return stop(evidence, stepResults.concat(rest(playbook, index + 1)), outcome);
      }

      evidence.push(record(step, "ok", page.texts, "step finished"));
      stepResults.push(pageStepResult(
        playbook.id,
        step,
        "ok",
        "executed",
        "step finished",
        Date.now() - started,
      ));
    }
    return { status: "completed", stopReason: null, evidence, stepResults };
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

function pageTarget(step: PagePlaybookStep): StepTarget {
  if (step.kind === "goto") {
    if (step.url !== undefined && step.url.length > 0) return { kind: "url", url: step.url };
    return { kind: "none" };
  }
  if (step.locator !== undefined && step.locator.length > 0) {
    return { kind: "locator", locator: step.locator };
  }
  return { kind: "none" };
}

function pageStepResult(
  playbookId: string,
  step: PagePlaybookStep,
  status: "ok" | "retryable" | "failed" | "protected",
  attempt: "executed" | "timeout" | "not_executed",
  summary: string,
  timingMs: number,
): StepResult {
  return emitStepResult({
    stepId: step.id,
    playbookId,
    adapter: "page",
    action: step.kind,
    status,
    attempt,
    target: pageTarget(step),
    summary,
    timingMs,
  });
}

function rest(playbook: PagePlaybook, startIndex: number): StepResult[] {
  return emitNotExecutedRest(playbook.id, "page", playbook.steps, startIndex, pageTarget);
}

function record(
  step: PagePlaybookStep,
  outcome: StepOutcome,
  pageTexts: readonly string[],
  note: string,
): StepEvidence {
  return { stepId: step.id, kind: step.kind, outcome, screenTexts: [...pageTexts], note };
}

function stop(
  evidence: StepEvidence[],
  stepResults: StepResult[],
  stopReason: Exclude<StepOutcome, "ok">,
): RunResult {
  return { status: "stopped", stopReason, evidence, stepResults };
}
