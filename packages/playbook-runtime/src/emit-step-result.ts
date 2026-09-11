import type {
  StepAction,
  StepAdapter,
  StepAttempt,
  StepResult,
  StepResultStatus,
  StepTarget,
} from "./step-result.ts";
import { parseStepResult } from "./step-result.ts";

export function emitStepResult(input: {
  readonly stepId: string;
  readonly playbookId: string;
  readonly adapter: StepAdapter;
  readonly action: StepAction;
  readonly status: StepResultStatus;
  readonly attempt: StepAttempt;
  readonly target: StepTarget;
  readonly summary: string;
  readonly timingMs: number;
}): StepResult {
  return parseStepResult({
    stepId: input.stepId,
    playbookId: input.playbookId,
    adapter: input.adapter,
    action: input.action,
    status: input.status,
    attempt: input.attempt,
    target: input.target,
    observation: { summary: input.summary },
    timingMs: input.timingMs,
  });
}

export function emitNotExecutedRest<T extends { readonly id: string; readonly kind: StepAction }>(
  playbookId: string,
  adapter: StepAdapter,
  steps: readonly T[],
  startIndex: number,
  targetOf: (step: T) => StepTarget,
): StepResult[] {
  return steps.slice(startIndex).map(step =>
    emitStepResult({
      stepId: step.id,
      playbookId,
      adapter,
      action: step.kind,
      status: "failed",
      attempt: "not_executed",
      target: targetOf(step),
      summary: "previous step stopped the run; adapter was not called",
      timingMs: 0,
    }),
  );
}
