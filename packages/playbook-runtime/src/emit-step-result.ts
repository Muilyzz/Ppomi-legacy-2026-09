import { isDriverTimeout } from "./adapter-timeout.ts";
import type { PageStepKind, StepKind, StepOutcome } from "./playbook.ts";
import { redactText } from "./public-url.ts";
import type { StepAttempt, StepDriver, StepResult, StepResultStatus, StepTarget } from "./step-result.ts";
import { withDeprecatedAdapter } from "./step-result.ts";

/**
 * The mapping from what the runtime observed to the model-facing `StepResult`.
 * Rows are built from closed types, never re-parsed per step: `parseStepResult`
 * is for untrusted input and dumps, and must not become a throw path inside a run.
 */

/** Reasons the runtime itself reports. Driver failures carry the driver's own code instead. */
export type RuntimeCode =
  | "permission_denied"
  | "no_effect"
  | "commit"
  | "read_failed"
  | "act_failed"
  | "timeout"
  | "screen_missing"
  | "focus_mismatch"
  | "target_required"
  | "target_not_on_screen"
  | "text_required"
  | "origin_not_declared"
  | "url_mismatch"
  | "page_missing"
  | "locator_required"
  | "locator_not_on_page"
  | "url_required"
  | "origins_required"
  | "navigation_refused";

export interface Decision {
  readonly outcome: StepOutcome;
  readonly status: StepResultStatus;
  readonly attempt: StepAttempt;
  /** `RuntimeCode` or the driver's own code; absent when the step is ok. */
  readonly code: string | null;
  readonly note: string;
}

/** Actions that may already have changed the device when a timeout is reported. Never retry them blindly. */
const MUTATING_ACTIONS: ReadonlySet<StepKind | PageStepKind> = new Set(["click", "fill", "type"]);

export const DONE: Decision = { outcome: "ok", status: "ok", attempt: "executed", code: null, note: "step finished" };

/** A plain permission stop is a failed step, not a protected control. */
export function refused(note: string): Decision {
  return { outcome: "permission_denied", status: "failed", attempt: "not_executed", code: "permission_denied", note };
}

export function handoff(undeclared: boolean): Decision {
  return {
    outcome: "handoff",
    status: "needs_human",
    attempt: "not_executed",
    code: undeclared ? "no_effect" : "commit",
    note: undeclared ? "no declared effect: the person takes this step" : "commit step: the person takes this step",
  };
}

/** Still unmet after a declared wait is a timeout; otherwise the screen did not match or the step is malformed. */
export function unmet(code: RuntimeCode, detail: string, waited: boolean): Decision {
  if (waited) return { outcome: "precondition_failed", status: "retryable", attempt: "timeout", code, note: detail };
  return { outcome: "precondition_failed", status: "failed", attempt: "not_executed", code, note: detail };
}

export type DriverPhase = "read" | "act";

/** Executor codes that mean the driver refused before touching the control. */
function refusedBeforeActing(code: string | null): boolean {
  return code === "stale_screen" || code === "protected_action" || (code !== null && code.startsWith("ambiguous"));
}

/**
 * The driver was reached and threw. `attempt` follows the phase: a failure while
 * reading the screen for a mutation means the mutation never ran
 * (`not_executed`); a refusal the driver raises before acting is also
 * `not_executed`; only an unknown error out of `act` is `executed`. A timeout on
 * a read, focus or navigation is retryable (navigation is idempotent); a timeout
 * on `click` / `fill` / `type` may already have changed the device, so it needs
 * a human, never a retry. `protected` is reserved for the driver's own
 * protected-control refusal (`protected_action`).
 */
export function driverFailed(error: unknown, phase: DriverPhase, action: StepKind | PageStepKind): Decision {
  // Driver messages (Playwright call logs, UIA text) may carry URLs with query tokens: keep one line, public URLs only.
  const note = redactText(error instanceof Error ? error.message : String(error));
  const driverCode = codeOf(error);
  const readIsTheStep = phase === "read" && action === "read";
  if (isDriverTimeout(error)) {
    const code = driverCode ?? "timeout";
    if (phase === "read") {
      return { outcome: "timeout", status: "retryable", attempt: readIsTheStep ? "timeout" : "not_executed", code, note };
    }
    return MUTATING_ACTIONS.has(action)
      ? { outcome: "timeout", status: "needs_human", attempt: "timeout", code, note }
      : { outcome: "timeout", status: "retryable", attempt: "timeout", code, note };
  }
  const code = driverCode ?? (phase === "read" ? "read_failed" : "act_failed");
  const attempt: StepAttempt = phase === "read"
    ? (readIsTheStep ? "executed" : "not_executed")
    : (refusedBeforeActing(driverCode) ? "not_executed" : "executed");
  switch (driverCode) {
    case "stale_screen":
      return { outcome: "failed", status: "retryable", attempt, code, note };
    case "protected_action":
      return { outcome: "failed", status: "protected", attempt, code, note };
    default:
      return { outcome: "failed", status: "failed", attempt, code, note };
  }
}

export function stepResultRow(input: {
  readonly stepId: string;
  readonly playbookId: string;
  readonly driver: StepDriver;
  readonly action: StepKind | PageStepKind;
  readonly decision: Decision;
  readonly target: StepTarget;
  readonly summary: string;
  readonly timingMs: number;
}): StepResult {
  const row: StepResult = {
    stepId: input.stepId,
    playbookId: input.playbookId,
    driver: input.driver,
    action: input.action,
    status: input.decision.status,
    attempt: input.decision.attempt,
    ...(input.decision.code !== null ? { code: input.decision.code } : {}),
    target: input.target,
    observation: { summary: input.summary },
    timingMs: Math.max(0, input.timingMs),
  };
  return withDeprecatedAdapter(row);
}

/** Steps after a stop: recorded, never sent to the driver. */
export function notExecutedRest<Step extends { readonly id: string; readonly kind: StepKind | PageStepKind }>(
  playbookId: string,
  driver: StepDriver,
  steps: readonly Step[],
  startIndex: number,
  targetOf: (step: Step) => StepTarget,
): StepResult[] {
  return steps.slice(startIndex).map(step =>
    stepResultRow({
      stepId: step.id,
      playbookId,
      driver,
      action: step.kind,
      decision: { outcome: "failed", status: "failed", attempt: "not_executed", code: "not_executed", note: "" },
      target: targetOf(step),
      summary: "previous step stopped the run; adapter was not called",
      timingMs: 0,
    }),
  );
}

function codeOf(error: unknown): string | null {
  if (error instanceof Error && "code" in error && typeof error.code === "string" && error.code.length > 0) return error.code;
  return null;
}
