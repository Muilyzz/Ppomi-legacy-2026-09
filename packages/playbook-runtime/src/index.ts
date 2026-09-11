export type { OsAdapter, OsAdapterKind, ScreenSnapshot } from "./os-adapter.ts";
export { AdapterTimeoutError, isAdapterTimeout } from "./adapter-timeout.ts";
export type { BrowserPageAdapter, PageSnapshot } from "./browser-page-adapter.ts";
export { DummyAdapter, type DummyCall } from "./dummy-adapter.ts";
export { DummyPageAdapter, type DummyPageCall } from "./dummy-page-adapter.ts";
export {
  FixedPermissionGate,
  defaultPagePermission,
  defaultPermission,
  type PermissionGate,
} from "./permissions.ts";
export {
  Runtime,
  requiredPermissions,
  type Resolution,
  type RuntimeCode,
  type RuntimeOptions,
  type RuntimePlaybook,
  type RuntimeStep,
  type StepClass,
  type Surface,
} from "./runtime-core.ts";
export { OsSurface, type OsRef } from "./os-surface.ts";
export { PageSurface, navigationRefusal, publicUrl, type PageRef } from "./page-surface.ts";
export { PlaybookRuntime } from "./playbook-runtime.ts";
export { PagePlaybookRuntime } from "./page-playbook-runtime.ts";
export type {
  MaybePromise,
  Permission,
  Playbook,
  PlaybookStep,
  PageStepKind,
  RunResult,
  RunStatus,
  StepEffect,
  StepEvidence,
  StepKind,
  StepOutcome,
  StepRequirement,
  SurfaceKind,
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
