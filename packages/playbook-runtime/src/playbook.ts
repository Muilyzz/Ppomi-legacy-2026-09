import type { StepResult } from "./step-result.ts";

/** UI step permissions only. Not a device-approval or Mac-approver gate. */
export type Permission = "ui.read" | "ui.control";

/** Adapters may be sync or async; the runtime awaits every call. */
export type MaybePromise<T> = T | Promise<T>;

/**
 * What a mutation does, declared by playbook data. In the core (`Runtime`) a
 * mutation with no declared effect is treated as `commit`, and `commit` steps
 * are never run: the runtime stops with a `handoff` so the person takes the step.
 */
export type StepEffect = "navigate" | "input" | "commit";

export type SurfaceKind = "os" | "page";

export type StepKind = "focus" | "click" | "type" | "read";

/** In-page steps for `BrowserPageAdapter`. Not OS screen-text `click` / `type`. */
export type PageStepKind = "goto" | "click" | "fill" | "waitFor" | "read";

export type StepOutcome =
  | "ok"
  | "permission_denied"
  | "precondition_failed"
  | "handoff"
  | "timeout"
  | "failed";

export type RunStatus = "completed" | "stopped";

export interface StepRequirement {
  /** Adds to the kind's default permission; it can never replace it. */
  readonly permission?: Permission;
  readonly screen?: readonly string[];
  readonly focused?: string;
  /** Poll the screen for up to this many milliseconds until the preconditions hold. */
  readonly wait?: number;
}

export interface PlaybookStep {
  readonly id: string;
  readonly kind: StepKind;
  readonly target?: string;
  readonly text?: string;
  readonly effect?: StepEffect;
  readonly require?: StepRequirement;
}

export interface Playbook {
  readonly id: string;
  readonly steps: readonly PlaybookStep[];
}

/** The runner log, one row per attempted step. `screenTexts` is bounded and never holds the typed text. */
export interface StepEvidence {
  readonly stepId: string;
  readonly kind: StepKind | PageStepKind;
  readonly outcome: StepOutcome;
  readonly screenTexts: readonly string[];
  readonly note: string;
}

export interface RunResult {
  readonly status: RunStatus;
  readonly stopReason: Exclude<StepOutcome, "ok"> | null;
  readonly evidence: readonly StepEvidence[];
  /** One `StepResult` per declared step, in playbook order; steps after a stop are `not_executed`. */
  readonly stepResults: readonly StepResult[];
}
