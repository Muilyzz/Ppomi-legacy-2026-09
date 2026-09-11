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
