import type { PageStepKind, Permission } from "./playbook.ts";

export interface PageStepRequirement {
  readonly permission?: Permission;
  readonly url?: string;
  readonly texts?: readonly string[];
}

export interface PagePlaybookStep {
  readonly id: string;
  readonly kind: PageStepKind;
  readonly url?: string;
  readonly locator?: string;
  readonly text?: string;
  readonly require?: PageStepRequirement;
}

/** In-page playbook for `PagePlaybookRuntime`. OS chrome uses `Playbook` + `PlaybookRuntime`. */
export interface PagePlaybook {
  readonly id: string;
  readonly steps: readonly PagePlaybookStep[];
}
