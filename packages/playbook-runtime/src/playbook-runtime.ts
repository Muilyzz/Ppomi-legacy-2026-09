import type { OsAdapter, ScreenSnapshot } from "./os-adapter.ts";
import { defaultPermission, type PermissionGate } from "./permissions.ts";
import type {
  Playbook,
  PlaybookStep,
  RunResult,
  StepEvidence,
  StepOutcome,
} from "./playbook.ts";

/**
 * Runs declared steps against one OS adapter.
 * Authors: native windows, system dialogs, cert UI, non-DOM chrome.
 * In-page DOM / forms / waits use `PagePlaybookRuntime` + `BrowserPageAdapter`.
 * See `docs/adapter-selection.md`. Do not wait in Playwright for a native modal.
 * Permission and screen/target preconditions are fail-closed: the run stops
 * and later steps are not sent to the adapter.
 * There is no device-approval or Mac-approver input.
 */
export class PlaybookRuntime {
  private readonly adapter: OsAdapter;
  private readonly permissions: PermissionGate;

  constructor(adapter: OsAdapter, permissions: PermissionGate) {
    this.adapter = adapter;
    this.permissions = permissions;
  }

  run(playbook: Playbook): RunResult {
    const evidence: StepEvidence[] = [];
    for (const step of playbook.steps) {
      const permission = step.require?.permission ?? defaultPermission(step.kind);
      if (!this.permissions.allows(permission)) {
        evidence.push(record(step, "permission_denied", [], `missing permission ${permission}`));
        return stop(evidence, "permission_denied");
      }

      const screen = this.adapter.readScreen();
      const why = unmetPrecondition(step, screen);
      if (why !== null) {
        evidence.push(record(step, "precondition_failed", screen.texts, why));
        return stop(evidence, "precondition_failed");
      }

      apply(this.adapter, step);
      evidence.push(record(step, "ok", screen.texts, "step finished"));
    }
    return { status: "completed", stopReason: null, evidence };
  }
}

function apply(adapter: OsAdapter, step: PlaybookStep): void {
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

function record(
  step: PlaybookStep,
  outcome: StepOutcome,
  screenTexts: readonly string[],
  note: string,
): StepEvidence {
  return { stepId: step.id, kind: step.kind, outcome, screenTexts: [...screenTexts], note };
}

function stop(evidence: StepEvidence[], stopReason: Exclude<StepOutcome, "ok">): RunResult {
  return { status: "stopped", stopReason, evidence };
}
