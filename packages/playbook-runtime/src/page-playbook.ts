import type { PageStepKind, Permission, StepEffect } from "./playbook.ts";

export interface PageStepRequirement {
  /** Adds to the kind's default permission; it can never replace it. */
  readonly permission?: Permission;
  /** Compared by origin + pathname; query and fragment are ignored. */
  readonly url?: string;
  readonly texts?: readonly string[];
  /** Locators that must be on the page. With `wait`, this replaces a `waitFor` step. */
  readonly locators?: readonly string[];
  /** Poll the page for up to this many milliseconds until the preconditions hold. */
  readonly wait?: number;
}

export interface PagePlaybookStep {
  readonly id: string;
  readonly kind: PageStepKind;
  readonly url?: string;
  readonly locator?: string;
  readonly text?: string;
  readonly effect?: StepEffect;
  readonly require?: PageStepRequirement;
}

export interface PagePlaybook {
  readonly id: string;
  /**
   * Origins `goto` may open and later steps may run on. When declared, any other
   * origin (including one reached by redirect) fails the next step's precondition.
   */
  readonly allowedOrigins?: readonly string[];
  readonly steps: readonly PagePlaybookStep[];
}
