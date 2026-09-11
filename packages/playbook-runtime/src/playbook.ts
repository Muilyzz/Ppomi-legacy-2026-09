/** UI step permissions only. Not a device-approval or Mac-approver gate. */
export type Permission = "ui.read" | "ui.control";

export type StepKind = "focus" | "click" | "type" | "read";

export type StepOutcome = "ok" | "permission_denied" | "precondition_failed";

export type RunStatus = "completed" | "stopped";

export interface StepRequirement {
  readonly permission?: Permission;
  readonly screen?: readonly string[];
  readonly focused?: string;
}

export interface PlaybookStep {
  readonly id: string;
  readonly kind: StepKind;
  readonly target?: string;
  readonly text?: string;
  readonly require?: StepRequirement;
}

export interface Playbook {
  readonly id: string;
  readonly steps: readonly PlaybookStep[];
}

export interface StepEvidence {
  readonly stepId: string;
  readonly kind: StepKind;
  readonly outcome: StepOutcome;
  readonly screenTexts: readonly string[];
  readonly note: string;
}

export interface RunResult {
  readonly status: RunStatus;
  readonly stopReason: Exclude<StepOutcome, "ok"> | null;
  readonly evidence: readonly StepEvidence[];
}
