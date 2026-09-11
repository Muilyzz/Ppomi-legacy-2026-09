/**
 * ppomi-brain — orchestration (choose path → check grant → run body → record).
 * Not ppomi-chat (conversation UI) and not Clerk UI.
 * Neighbors: ppomi-path (catalog), ppomi-body / playbook-runtime (actuation), ppomi-account (org/seat).
 */
export type { ActionEffect, ExecutionSurface, GrantDecision, PathGrant, SessionIdentity } from "./grant.ts";
export { allowGrant, denyGrant, describeEffect, inspectGrant } from "./grant.ts";
export type { PathDefinition, PathStep, PathSummary, RunIntent } from "./path.ts";
export { choosePath, grantableEffects } from "./path.ts";
export type {
  AccountSession,
  BodyRunInput,
  BodyRunResult,
  BodyRuntime,
  BodyStepResult,
  BodyStepStatus,
  BodyStopReason,
  BrainPorts,
  DeviceListScope,
  DeviceOs,
  DeviceRegistry,
  DeviceSessionAttach,
  FleetDevice,
  Memory,
  MemoryEvent,
  PathCatalog,
  PathLoader,
} from "./ports.ts";
export { DEVICE_OS } from "./ports.ts";
export type { OrchestrationResult, OrchestrationStatus } from "./orchestrate.ts";
export { PpomiBrain, orchestrate } from "./orchestrate.ts";
export type { BodyRoute, BodyRouteSurface } from "./fleet.ts";
export {
  InMemoryDeviceRegistry,
  isDeviceOs,
  preferredOsForSurface,
  routeBody,
  routeBodyForSurface,
} from "./fleet.ts";
export type {
  LegacyPlaybook,
  LegacyPlaybookRunner,
  LegacyPlaybookStep,
  LegacyRunResult,
} from "./wiring/playbook-runtime-body.ts";
export { bodyFromPlaybookRuntime } from "./wiring/playbook-runtime-body.ts";
