export type { OsAdapter, ScreenSnapshot } from "./os-adapter.ts";
export type { BrowserPageAdapter, PageSnapshot } from "./browser-page-adapter.ts";
export { DummyAdapter, type DummyCall } from "./dummy-adapter.ts";
export { DummyPageAdapter, type DummyPageCall } from "./dummy-page-adapter.ts";
export {
  FixedPermissionGate,
  defaultPagePermission,
  defaultPermission,
  type PermissionGate,
} from "./permissions.ts";
export { PlaybookRuntime } from "./playbook-runtime.ts";
export { PagePlaybookRuntime } from "./page-playbook-runtime.ts";
export type {
  Permission,
  Playbook,
  PlaybookStep,
  PageStepKind,
  RunResult,
  RunStatus,
  StepEvidence,
  StepKind,
  StepOutcome,
  StepRequirement,
} from "./playbook.ts";
export type {
  PagePlaybook,
  PagePlaybookStep,
  PageStepRequirement,
} from "./page-playbook.ts";
export {
  dumpStepResults,
  parseStepResult,
  parseStepResults,
  parseStepResultsJson,
  StepResultError,
} from "./step-result.ts";
export type {
  Evidence,
  StepAction,
  StepAdapter,
  StepAttempt,
  StepObservation,
  StepResult,
  StepResultStatus,
  StepTarget,
} from "./step-result.ts";
