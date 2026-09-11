import type { PermissionGate } from "./permissions.ts";
import type { PageStepKind, Permission, StepEffect, StepKind } from "./playbook.ts";
import type { RunResult, RuntimeCode, StepResult, StepStatus, SurfaceKind } from "./step-result.ts";

/** The part of a step the core reads itself; surfaces interpret the rest. */
export interface RuntimeStep {
  readonly id: string;
  readonly kind: StepKind | PageStepKind;
  readonly effect?: StepEffect;
  readonly require?: {
    readonly permission?: Permission;
    readonly wait?: number;
  };
}

export interface RuntimePlaybook<Step extends RuntimeStep> {
  readonly id: string;
  readonly steps: readonly Step[];
}

export interface StepClass {
  /** The kind's own permission. `ui.read` is required by every step in addition. */
  readonly permission: Permission;
  /** Mutations need a declared `effect`; without one they are handed off, never run. */
  readonly mutation: boolean;
}

export type Resolution<Ref> =
  | { readonly ok: true; readonly ref: Ref }
  | { readonly ok: false; readonly code: RuntimeCode; readonly detail: string };

/**
 * One observable surface (OS screen, web page). The core owns permissions,
 * effect gating, polling, results and failure handling; a surface only reads,
 * resolves declared targets against a snapshot, and acts on a resolved target.
 */
export interface Surface<Snap, Ref, Step extends RuntimeStep> {
  readonly kind: SurfaceKind;
  read(): Promise<Snap>;
  /** Texts observed in the snapshot; the runtime bounds them. */
  observed(snap: Snap): readonly string[];
  /** Origin + pathname when the surface has a location, else `null`. */
  location(snap: Snap): string | null;
  classify(step: Step): StepClass;
  resolve(snap: Snap, step: Step): Resolution<Ref>;
  act(step: Step, ref: Ref): Promise<void>;
}

export interface RuntimeOptions {
  readonly pollIntervalMs?: number;
  readonly maxObservedTexts?: number;
  readonly maxObservedTextLength?: number;
  readonly maxDetailLength?: number;
  readonly sleep?: (ms: number) => Promise<void>;
  readonly now?: () => number;
}

const DEFAULTS = {
  pollIntervalMs: 100,
  maxObservedTexts: 200,
  maxObservedTextLength: 200,
  maxDetailLength: 300,
} as const;

/**
 * `ui.read` (every step observes the surface) plus the kind's own permission plus
 * anything the step declares. Data can add a requirement, never remove one.
 */
export function requiredPermissions(step: RuntimeStep, kindPermission: Permission): readonly Permission[] {
  const required = new Set<Permission>(["ui.read", kindPermission]);
  const declared = step.require?.permission;
  if (declared !== undefined) required.add(declared);
  return [...required];
}

/**
 * Runs declared steps against one surface. Fail-closed at every gate: a missing
 * permission, an undeclared or `commit` effect, an unmet precondition after the
 * declared wait, or an adapter failure stops the run with a `StepResult` and
 * sends nothing further to the adapter. `completed` means the declared steps
 * finished; it is not a business-result claim.
 */
export class Runtime<Snap, Ref, Step extends RuntimeStep> {
  private readonly surface: Surface<Snap, Ref, Step>;
  private readonly permissions: PermissionGate;
  private readonly pollIntervalMs: number;
  private readonly maxObservedTexts: number;
  private readonly maxObservedTextLength: number;
  private readonly maxDetailLength: number;
  private readonly sleep: (ms: number) => Promise<void>;
  private readonly now: () => number;

  constructor(surface: Surface<Snap, Ref, Step>, permissions: PermissionGate, options: RuntimeOptions = {}) {
    this.surface = surface;
    this.permissions = permissions;
    this.pollIntervalMs = options.pollIntervalMs ?? DEFAULTS.pollIntervalMs;
    this.maxObservedTexts = options.maxObservedTexts ?? DEFAULTS.maxObservedTexts;
    this.maxObservedTextLength = options.maxObservedTextLength ?? DEFAULTS.maxObservedTextLength;
    this.maxDetailLength = options.maxDetailLength ?? DEFAULTS.maxDetailLength;
    this.sleep = options.sleep ?? (ms => new Promise(resolve => setTimeout(resolve, ms)));
    this.now = options.now ?? (() => Date.now());
  }

  async run(playbook: RuntimePlaybook<Step>): Promise<RunResult> {
    const evidence: StepResult[] = [];
    let last: Snap | null = null;
    const finish = (status: RunResult["status"], stopReason: RunResult["stopReason"]): RunResult => {
      const texts = last === null ? [] : this.surface.observed(last);
      return {
        status,
        stopReason,
        evidence,
        observed: texts.slice(0, this.maxObservedTexts).map(text => text.slice(0, this.maxObservedTextLength)),
        observedTruncated: texts.length > this.maxObservedTexts || texts.some(text => text.length > this.maxObservedTextLength),
      };
    };
    const stop = (step: Step, status: Exclude<StepStatus, "done">, code: string, detail: string): RunResult => {
      evidence.push(this.record(step, status, code, detail, last));
      return finish("stopped", status);
    };

    for (const step of playbook.steps) {
      const cls = this.surface.classify(step);
      const denied = requiredPermissions(step, cls.permission).find(permission => !this.permissions.allows(permission));
      if (denied !== undefined) return stop(step, "refused", "missing_permission", `missing permission ${denied}`);

      let snap: Snap;
      try {
        snap = await this.surface.read();
      } catch (error) {
        return stop(step, "adapter_failed", codeOf(error, "read_failed"), `read failed: ${messageOf(error)}`);
      }
      last = snap;

      if (cls.mutation && (step.effect ?? "commit") === "commit") {
        return step.effect === undefined
          ? stop(step, "handoff", "no_effect", "no declared effect: the person takes this step")
          : stop(step, "handoff", "commit", "commit step: the person takes this step");
      }

      let resolution = this.surface.resolve(snap, step);
      const deadline = this.now() + (step.require?.wait ?? 0);
      while (!resolution.ok && this.now() < deadline) {
        await this.sleep(this.pollIntervalMs);
        try {
          snap = await this.surface.read();
        } catch (error) {
          return stop(step, "adapter_failed", codeOf(error, "read_failed"), `read failed: ${messageOf(error)}`);
        }
        last = snap;
        resolution = this.surface.resolve(snap, step);
      }
      if (!resolution.ok) return stop(step, "unmet", resolution.code, resolution.detail);

      try {
        await this.surface.act(step, resolution.ref);
      } catch (error) {
        return stop(step, "adapter_failed", codeOf(error, "act_failed"), `adapter failed: ${messageOf(error)}`);
      }
      evidence.push(this.record(step, "done", null, "step finished", snap));
    }
    return finish("completed", null);
  }

  private record(step: Step, status: StepStatus, code: string | null, detail: string, snap: Snap | null): StepResult {
    return {
      stepId: step.id,
      kind: step.kind,
      surface: this.surface.kind,
      status,
      code,
      url: snap === null ? null : this.surface.location(snap),
      at: this.now(),
      detail: detail.slice(0, this.maxDetailLength),
    };
  }
}

/** Executor refusals arrive as errors with a string `code`; keep it as the structured reason. */
function codeOf(error: unknown, fallback: RuntimeCode): string {
  if (error instanceof Error && "code" in error && typeof error.code === "string" && error.code.length > 0) return error.code;
  return fallback;
}

/** Adapter messages must not echo typed text; the runtime only bounds them. */
function messageOf(error: unknown): string {
  return error instanceof Error ? error.message : String(error);
}
