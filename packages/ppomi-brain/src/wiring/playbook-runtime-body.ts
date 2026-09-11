import type { ActionEffect } from "../grant.ts";
import type { PathStep } from "../path.ts";
import type { BodyRunResult, BodyRuntime, BodyStepResult, BodyStepStatus } from "../ports.ts";

/**
 * Structural stand-in for `ppomi-body` `Runtime` / deprecated `PlaybookRuntime`.
 * Wiring / tests only. Surface packages are `ppomi-body-*`.
 */
export interface LegacyPlaybookRunner {
  run(playbook: LegacyPlaybook): LegacyRunResult;
}

export interface LegacyPlaybook {
  readonly id: string;
  readonly steps: readonly LegacyPlaybookStep[];
}

export interface LegacyPlaybookStep {
  readonly id: string;
  readonly kind: "focus" | "click" | "type" | "read";
  readonly target?: string;
}

export interface LegacyRunResult {
  readonly status: "completed" | "stopped";
  readonly stopReason: string | null;
  readonly evidence: readonly {
    readonly stepId: string;
    readonly outcome: string;
    readonly note: string;
  }[];
}

/** Map ppomi-brain BodyRuntime onto current ppomi-body without importing it. */
export function bodyFromPlaybookRuntime(runtime: LegacyPlaybookRunner): BodyRuntime {
  return {
    run({ path, grant }) {
      const playbook = {
        id: path.id,
        steps: path.steps.map(toLegacyStep),
      };
      const legacy = runtime.run(playbook);
      const steps: BodyStepResult[] = path.steps.flatMap(step => {
        const row = legacy.evidence.find(item => item.stepId === step.id);
        if (row === undefined) return [];
        return [{
          stepId: step.id,
          effect: step.effect,
          status: mapOutcome(row.outcome, step.effect, grant.effects),
          note: row.note,
        }];
      });
      return toBodyResult(legacy, steps);
    },
  };
}

function toLegacyStep(step: PathStep): LegacyPlaybookStep {
  switch (step.effect) {
    case "lookup":
      return { id: step.id, kind: "read" };
    case "save":
    case "input":
    case "transmit":
      return { id: step.id, kind: "click", target: step.title };
    case "financial_submit":
      return { id: step.id, kind: "click", target: step.title };
    default: {
      const exhaustive: never = step.effect;
      return exhaustive;
    }
  }
}

function mapOutcome(
  outcome: string,
  effect: ActionEffect,
  granted: readonly ActionEffect[],
): BodyStepStatus {
  switch (outcome) {
    case "ok":
      if (effect === "financial_submit") return "protected";
      if (!granted.includes(effect)) return "grant_denied";
      return "ok";
    case "permission_denied":
      return "grant_denied";
    case "protected_action":
    case "protected":
      return "protected";
    case "needs_human":
      return "needs_human";
    default:
      return "failed";
  }
}

function toBodyResult(legacy: LegacyRunResult, steps: readonly BodyStepResult[]): BodyRunResult {
  const blocking = steps.find(step => step.status !== "ok");
  if (blocking !== undefined && blocking.status !== "ok") {
    return { status: "stopped", stopReason: blocking.status, steps };
  }
  if (legacy.status === "completed") {
    return { status: "completed", stopReason: null, steps };
  }
  return { status: "stopped", stopReason: "failed", steps };
}
