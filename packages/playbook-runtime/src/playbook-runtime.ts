import { isAdapterTimeout } from "./adapter-timeout.ts";
import { emitNotExecutedRest, emitStepResult } from "./emit-step-result.ts";
import type { OsUiDriver, ScreenSnapshot } from "./os-adapter.ts";
import { defaultPermission, type PermissionGate } from "./permissions.ts";
import type {
  Playbook,
  PlaybookStep,
  RunResult,
  StepEvidence,
  StepOutcome,
} from "./playbook.ts";
import type { StepAdapter, StepResult, StepTarget } from "./step-result.ts";

/**
 * Runs declared steps against one OS adapter.
 * Authors: native windows, system dialogs, cert UI, non-DOM chrome.
 * In-page DOM / forms / waits use `PagePlaybookRuntime` + `BrowserPageDriver`.
 * See `docs/adapter-selection.md`. Do not wait in Playwright for a native modal.
 * Permission and screen/target preconditions are fail-closed: the run stops
 * and later steps are not sent to the adapter.
 * `RunResult.evidence` is the runner log. `RunResult.stepResults` is one
 * `StepResult` per declared step (`attempt` distinguishes timeout from
 * not_executed). Adapter kind comes from the injected `OsUiDriver`.
 * There is no device-approval or Mac-approver input.
 */
export class PlaybookRuntime {
  private readonly adapter: OsUiDriver;
  private readonly permissions: PermissionGate;

  constructor(adapter: OsUiDriver, permissions: PermissionGate) {
    this.adapter = adapter;
    this.permissions = permissions;
  }

  run(playbook: Playbook): RunResult {
    const evidence: StepEvidence[] = [];
    const stepResults: StepResult[] = [];
    const adapterKind = this.adapter.kind;
    for (let index = 0; index < playbook.steps.length; index += 1) {
      const step = playbook.steps[index]!;
      const permission = step.require?.permission ?? defaultPermission(step.kind);
      if (!this.permissions.allows(permission)) {
        const note = `missing permission ${permission}`;
        evidence.push(record(step, "permission_denied", [], note));
        stepResults.push(
          osStepResult(playbook.id, adapterKind, step, "protected", "not_executed", note, 0),
        );
        return stop(
          evidence,
          stepResults.concat(rest(playbook, adapterKind, index + 1)),
          "permission_denied",
        );
      }

      const screen = this.adapter.readScreen();
      const why = unmetPrecondition(step, screen);
      if (why !== null) {
        evidence.push(record(step, "precondition_failed", screen.texts, why));
        stepResults.push(
          osStepResult(playbook.id, adapterKind, step, "failed", "not_executed", why, 0),
        );
        return stop(
          evidence,
          stepResults.concat(rest(playbook, adapterKind, index + 1)),
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
        evidence.push(record(step, outcome, screen.texts, note));
        stepResults.push(osStepResult(
          playbook.id,
          adapterKind,
          step,
          timeout ? "retryable" : "failed",
          timeout ? "timeout" : "executed",
          note,
          timingMs,
        ));
        return stop(
          evidence,
          stepResults.concat(rest(playbook, adapterKind, index + 1)),
          outcome,
        );
      }

      evidence.push(record(step, "ok", screen.texts, "step finished"));
      stepResults.push(osStepResult(
        playbook.id,
        adapterKind,
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

function apply(adapter: OsUiDriver, step: PlaybookStep): void {
  switch (step.kind) {
    case "read":
      return;
    case "focus":
      adapter.focus(step.target!);
      return;
    case "click":
      adapter.click(step.target!);
      return;
    case "type":
      adapter.type(step.target!, step.text!);
      return;
    default: {
      const exhaustive: never = step.kind;
      throw new Error(`unhandled step kind: ${String(exhaustive)}`);
    }
  }
}

function unmetPrecondition(step: PlaybookStep, screen: ScreenSnapshot): string | null {
  const required = step.require?.screen ?? [];
  const missing = required.filter(text => !screen.texts.includes(text));
  if (missing.length > 0) return `screen missing ${missing.join(", ")}`;

  if (step.require?.focused !== undefined && screen.focused !== step.require.focused) {
    return `focused ${screen.focused ?? "(none)"} !== ${step.require.focused}`;
  }

  if (step.kind === "read") return null;

  if (step.target === undefined || step.target.length === 0) return "step target is required";
  if (!onScreen(screen, step.target)) return `target not on screen: ${step.target}`;
  if (step.kind === "type" && step.text === undefined) return "type step text is required";
  return null;
}

function onScreen(screen: ScreenSnapshot, target: string): boolean {
  return screen.focused === target || screen.texts.includes(target);
}

function osTarget(step: PlaybookStep): StepTarget {
  if (step.target !== undefined && step.target.length > 0) {
    return { kind: "accessibility", name: step.target };
  }
  return { kind: "none" };
}

function osStepResult(
  playbookId: string,
  adapter: StepAdapter,
  step: PlaybookStep,
  status: "ok" | "retryable" | "failed" | "protected",
  attempt: "executed" | "timeout" | "not_executed",
  summary: string,
  timingMs: number,
): StepResult {
  return emitStepResult({
    stepId: step.id,
    playbookId,
    adapter,
    action: step.kind,
    status,
    attempt,
    target: osTarget(step),
    summary,
    timingMs,
  });
}

function rest(playbook: Playbook, adapter: StepAdapter, startIndex: number): StepResult[] {
  return emitNotExecutedRest(playbook.id, adapter, playbook.steps, startIndex, osTarget);
}

function record(
  step: PlaybookStep,
  outcome: StepOutcome,
  screenTexts: readonly string[],
  note: string,
): StepEvidence {
  return { stepId: step.id, kind: step.kind, outcome, screenTexts: [...screenTexts], note };
}

function stop(
  evidence: StepEvidence[],
  stepResults: StepResult[],
  stopReason: Exclude<StepOutcome, "ok">,
): RunResult {
  return { status: "stopped", stopReason, evidence, stepResults };
}
