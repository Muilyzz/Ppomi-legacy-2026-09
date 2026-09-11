import type { ActionEffect, GrantDecision, PathGrant, SessionIdentity } from "./grant.ts";
import type { PathDefinition, PathSummary } from "./path.ts";

/** ppomi-path catalog. List only — load is PathLoader. */
export interface PathCatalog {
  list(): readonly PathSummary[] | Promise<readonly PathSummary[]>;
}

/** ppomi-path loader. Returns null when the id is unknown. */
export interface PathLoader {
  load(id: string): PathDefinition | null | Promise<PathDefinition | null>;
}

export interface BodyRunInput {
  readonly path: PathDefinition;
  readonly grant: PathGrant;
}

export type BodyStepStatus = "ok" | "grant_denied" | "needs_human" | "protected" | "failed";

export interface BodyStepResult {
  readonly stepId: string;
  readonly effect: ActionEffect;
  readonly status: BodyStepStatus;
  readonly note: string;
}

export type BodyStopReason = Exclude<BodyStepStatus, "ok">;

export interface BodyRunResult {
  readonly status: "completed" | "stopped";
  readonly stopReason: BodyStopReason | null;
  readonly steps: readonly BodyStepResult[];
}

/**
 * ppomi-body (today: playbook-runtime). Brain never calls OS drivers itself.
 * A payment-like step must stop as needs_human / protected — not ok.
 */
export interface BodyRuntime {
  run(input: BodyRunInput): BodyRunResult | Promise<BodyRunResult>;
}

/** ppomi-account org/seat. Clerk UI is not this port. */
export interface AccountSession {
  current(): SessionIdentity | null | Promise<SessionIdentity | null>;
  /** Narrow grant for this path only. Must not issue financial_submit. */
  grantFor(
    path: PathDefinition,
    identity: SessionIdentity,
  ): GrantDecision | Promise<GrantDecision>;
}

/** App-logged-in machines. Clerk says who; this says where. Account-only is not a fleet. */
export const DEVICE_OS = ["macos", "windows", "android", "ios"] as const;
export type DeviceOs = (typeof DEVICE_OS)[number];

export interface FleetDevice {
  readonly id: string;
  readonly os: DeviceOs;
  readonly online: boolean;
  readonly lastSeen: string;
  readonly ownerId: string;
  readonly orgId?: string;
}

/** Login / session attach. Mac and Windows each call this to appear in the fleet. */
export interface DeviceSessionAttach {
  readonly deviceId: string;
  readonly os: DeviceOs;
  readonly ownerId: string;
  readonly orgId?: string;
  /** Test clock. Production callers omit this; attach stamps now. */
  readonly lastSeen?: string;
}

export interface DeviceListScope {
  readonly ownerId: string;
  readonly orgId?: string;
}

/**
 * Device registry port. In-memory fake for tests; a later store implements the same upsert.
 * Do not put tokens, passwords, or keys on this port.
 */
export interface DeviceRegistry {
  attach(input: DeviceSessionAttach): FleetDevice | Promise<FleetDevice>;
  list(scope: DeviceListScope): readonly FleetDevice[] | Promise<readonly FleetDevice[]>;
}

export interface MemoryEvent {
  readonly kind: "run";
  readonly pathId: string;
  readonly status: string;
  readonly note: string;
}

/** Optional memory hook. Absence must not change grant or body behavior. */
export interface Memory {
  record(event: MemoryEvent): void | Promise<void>;
}

export interface BrainPorts {
  readonly paths: PathCatalog & PathLoader;
  readonly body: BodyRuntime;
  readonly session: AccountSession;
  readonly memory?: Memory;
}
