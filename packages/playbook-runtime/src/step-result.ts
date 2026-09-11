/**
 * The model-facing result shape. This module is the swap point for the MZZ-34
 * StepResult / Evidence schema: everything the runtime reports about a step
 * goes through `StepResult` and `RunResult`, and nothing here carries
 * coordinates, typed text, query strings or fragments.
 */
export type SurfaceKind = "os" | "page";

export type StepStatus = "done" | "refused" | "unmet" | "handoff" | "adapter_failed";

/** Reasons the runtime itself reports. Adapter failures carry the adapter's own code instead. */
export type RuntimeCode =
  | "missing_permission"
  | "no_effect"
  | "commit"
  | "read_failed"
  | "act_failed"
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
  | "navigation_refused";

export interface StepResult {
  readonly stepId: string;
  readonly kind: string;
  readonly surface: SurfaceKind;
  readonly status: StepStatus;
  /** `null` when done; otherwise a `RuntimeCode` or the adapter's error code. */
  readonly code: string | null;
  /** Origin + pathname of the page the step ran on, when the surface has one. Never query or fragment. */
  readonly url: string | null;
  /** Milliseconds since the epoch when the step was decided. */
  readonly at: number;
  /** Short human-readable detail, bounded by the runtime. Never the typed text. */
  readonly detail: string;
}

export type RunStatus = "completed" | "stopped";

export interface RunResult {
  readonly status: RunStatus;
  readonly stopReason: Exclude<StepStatus, "done"> | null;
  readonly evidence: readonly StepResult[];
  /** Texts observed on the last snapshot, bounded, so a person or model can continue from the stop point. */
  readonly observed: readonly string[];
  readonly observedTruncated: boolean;
}

/** @deprecated Renamed to `StepStatus`. */
export type StepOutcome = StepStatus;
/** @deprecated Renamed to `StepResult`. */
export type StepEvidence = StepResult;
