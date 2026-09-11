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
export {
  Runtime,
  requiredPermissions,
  type Resolution,
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
  StepEffect,
  StepKind,
  StepRequirement,
} from "./playbook.ts";
export type {
  RunResult,
  RunStatus,
  RuntimeCode,
  StepEvidence,
  StepOutcome,
  StepResult,
  StepStatus,
  SurfaceKind,
} from "./step-result.ts";
export type {
  PagePlaybook,
  PagePlaybookStep,
  PageStepRequirement,
} from "./page-playbook.ts";
