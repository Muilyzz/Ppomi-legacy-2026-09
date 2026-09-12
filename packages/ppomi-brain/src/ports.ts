import type { PathSurface } from "../../ppomi-path/src/schema.ts";
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

/**
 * App-logged-in machines. Clerk says who; this says where. Account-only is not a fleet.
 * Every id is opaque (the product's device id / auth subject / org id, `isOpaqueId`):
 * never an email, hostname, display name or a 사업자등록번호-shaped number.
 */
export const DEVICE_OS = ["macos", "windows", "android", "ios"] as const;
export type DeviceOs = (typeof DEVICE_OS)[number];

/** Body surfaces a device can serve: the `ppomi-path` surface ids, no aliases. */
export type FleetSurface = PathSurface;

export interface FleetDevice {
  readonly id: string;
  readonly os: DeviceOs;
  /** Capabilities a device declared at attach, limited by `ALLOWED_SERVES[os]`. */
  readonly serves: readonly FleetSurface[];
  /** Epoch milliseconds on the registry clock. `online` is derived from it, never stored. */
  readonly lastSeen: number;
  readonly ownerId: string;
  readonly orgId?: string;
}

/** Login / session attach. Mac and Windows each call this to appear in the fleet. */
export interface DeviceSessionAttach {
  readonly deviceId: string;
  readonly os: DeviceOs;
  readonly ownerId: string;
  readonly orgId?: string;
  /** Omitted → `DEFAULT_SERVES[os]`. */
  readonly serves?: readonly FleetSurface[];
  /** ISO 8601 as the device reports it; parsed, never ahead of the registry clock. Omitted → now. */
  readonly lastSeen?: string;
}

export type AttachRefusal =
  | "invalid_device_id"
  | "invalid_owner_id"
  | "invalid_org_id"
  | "invalid_os"
  | "invalid_surface"
  | "invalid_last_seen"
  | "owner_mismatch"
  | "os_mismatch";

export type AttachResult =
  | { readonly ok: true; readonly device: FleetDevice }
  | { readonly ok: false; readonly code: AttachRefusal; readonly detail: string };

export type DetachRefusal = "invalid_device_id" | "invalid_owner_id" | "invalid_org_id" | "not_found";

export type DetachResult =
  | { readonly ok: true }
  | { readonly ok: false; readonly code: DetachRefusal; readonly detail: string };

/** Personal scope is `orgId` undefined and lists personal devices only; an org scope lists that org only. */
export interface DeviceListScope {
  readonly ownerId: string;
  readonly orgId?: string;
}

/** Epoch milliseconds. Injected so presence is testable and never read from the device. */
export interface FleetClock {
  now(): number;
}

/** A device is online while `now - lastSeen <= staleAfterMs`. */
export interface FleetPresence {
  readonly clock: FleetClock;
  readonly staleAfterMs: number;
}

/**
 * Device registry port. In-memory fake for tests; a durable store keeps the same refusals:
 * an id already attached to another owner/org or OS is never re-owned by attach.
 * Do not put tokens, passwords, or keys on this port.
 */
export interface DeviceRegistry {
  readonly presence: FleetPresence;
  attach(input: DeviceSessionAttach): AttachResult | Promise<AttachResult>;
  detach(deviceId: string, scope: DeviceListScope): DetachResult | Promise<DetachResult>;
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
