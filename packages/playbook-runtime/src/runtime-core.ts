import {
  DONE,
  driverFailed,
  handoff,
  notExecutedRest,
  refused,
  stepResultRow,
  unmet,
  type Decision,
  type RuntimeCode,
} from "./emit-step-result.ts";
import type { PermissionGate } from "./permissions.ts";
import type {
  MaybePromise,
  PageStepKind,
  Permission,
  RunInvalid,
  RunResult,
  StepEffect,
  StepEvidence,
  StepKind,
  SurfaceKind,
} from "./playbook.ts";
import type { StepDriver, StepResult, StepTarget } from "./step-result.ts";

/** The part of a step the core reads itself; drivers interpret the rest. */
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
  /** Mutations need a declared `effect`; without one the core hands them off, never runs them. */
  readonly mutation: boolean;
}

export type Resolution<Ref> =
  | { readonly ok: true; readonly ref: Ref }
  | { readonly ok: false; readonly code: RuntimeCode; readonly detail: string };

/**
 * One UI driver as the runtime sees it: an eye (`read`) and a hand (`act`) over one
 * surface (OS screen, web page). The core owns permissions, effect gating, polling,
 * results and failure handling; the driver only reads, resolves declared targets
 * against a snapshot, and acts on a resolved target. `read` and `act` may be sync
 * or async; `Runtime.run` awaits them and `Runtime.runSync` requires them to be sync.
 */
export interface UiDriver<Snap, Ref, Step extends RuntimeStep> {
  readonly surface: SurfaceKind;
  /** Which driver family this is, copied onto every `StepResult`; `undefined` when the port did not say. */
  readonly driver: StepDriver | undefined;
  read(): MaybePromise<Snap>;
  /** Texts observed in the snapshot; the runtime bounds them. */
  observed(snap: Snap): readonly string[];
  /** The step's declared target as an observation-bound ref (never coordinates or node ids). */
  target(step: Step): StepTarget;
  classify(step: Step): StepClass;
  resolve(snap: Snap, step: Step): Resolution<Ref>;
  act(step: Step, ref: Ref): MaybePromise<void>;
}

export interface RuntimeOptions {
  /**
   * `handoff` (default): a mutation without a declared effect is a `commit` and stops the run.
   * `run`: legacy behaviour for the deprecated wrappers only — undeclared mutations execute.
   * A declared `commit` is handed off in both modes.
   */
  readonly undeclaredMutations?: "handoff" | "run";
  /** Fallback `StepResult.driver` when the port does not declare its kind. */
  readonly driver?: StepDriver;
  readonly pollIntervalMs?: number;
  readonly maxEvidenceTexts?: number;
  readonly maxEvidenceTextLength?: number;
  readonly maxNoteLength?: number;
  readonly sleep?: (ms: number) => Promise<void>;
  readonly sleepSync?: (ms: number) => void;
  readonly now?: () => number;
}

const DEFAULTS = {
  pollIntervalMs: 100,
  maxEvidenceTexts: 200,
  maxEvidenceTextLength: 200,
  maxNoteLength: 300,
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

/** Playbook data is checked once, up front; nothing inside the loop throws on data. */
export function validatePlaybook(playbook: RuntimePlaybook<RuntimeStep>): RunInvalid | null {
  if (playbook.id.length === 0) return { code: "empty_playbook_id", detail: "playbook id is required" };
  const seen = new Set<string>();
  for (const step of playbook.steps) {
    if (step.id.length === 0) return { code: "empty_step_id", detail: "every step needs a non-empty id" };
    if (seen.has(step.id)) return { code: "duplicate_step_id", detail: `duplicate step id: ${step.id}` };
    seen.add(step.id);
  }
  return null;
}

type Effect<Ref, Step> =
  | { readonly type: "read" }
  | { readonly type: "act"; readonly step: Step; readonly ref: Ref }
  | { readonly type: "sleep"; readonly ms: number };

/**
 * Runs declared steps against one driver. Fail-closed at every gate: a missing
 * permission, an undeclared or `commit` effect, an unmet precondition after the
 * declared wait, or a driver failure stops the run with an evidence row and a
 * `StepResult`, marks the remaining steps `not_executed`, and sends nothing
 * further to the driver. `completed` means the declared steps finished; it is
 * not a business-result claim.
 */
export class Runtime<Snap, Ref, Step extends RuntimeStep> {
  private readonly driver: UiDriver<Snap, Ref, Step>;
  private readonly permissions: PermissionGate;
  private readonly undeclaredMutations: "handoff" | "run";
  private readonly driverName: StepDriver | undefined;
  private readonly pollIntervalMs: number;
  private readonly maxEvidenceTexts: number;
  private readonly maxEvidenceTextLength: number;
  private readonly maxNoteLength: number;
  private readonly sleep: (ms: number) => Promise<void>;
  private readonly sleepSync: (ms: number) => void;
  private readonly now: () => number;

  constructor(driver: UiDriver<Snap, Ref, Step>, permissions: PermissionGate, options: RuntimeOptions = {}) {
    this.driver = driver;
    this.permissions = permissions;
    this.undeclaredMutations = options.undeclaredMutations ?? "handoff";
    this.driverName = driver.driver ?? options.driver;
    this.pollIntervalMs = options.pollIntervalMs ?? DEFAULTS.pollIntervalMs;
    this.maxEvidenceTexts = options.maxEvidenceTexts ?? DEFAULTS.maxEvidenceTexts;
    this.maxEvidenceTextLength = options.maxEvidenceTextLength ?? DEFAULTS.maxEvidenceTextLength;
    this.maxNoteLength = options.maxNoteLength ?? DEFAULTS.maxNoteLength;
    this.sleep = options.sleep ?? (ms => new Promise(resolve => setTimeout(resolve, ms)));
    this.sleepSync = options.sleepSync ?? blockingSleep;
    this.now = options.now ?? (() => Date.now());
  }

  /** Async driver loop: awaits every driver call. Use this for real drivers. */
  async run(playbook: RuntimePlaybook<Step>): Promise<RunResult> {
    const loop = this.loop(playbook);
    let next = loop.next();
    while (!next.done) {
      const effect = next.value;
      let value: unknown;
      try {
        value = effect.type === "sleep" ? await this.sleep(effect.ms) : await this.perform(effect);
      } catch (error) {
        next = loop.throw(error);
        continue;
      }
      next = loop.next(value);
    }
    return next.value;
  }

  /** Sync loop for sync drivers (fixtures, UIA/AX bridges that block). Throws on a Promise-returning driver. */
  runSync(playbook: RuntimePlaybook<Step>): RunResult {
    const loop = this.loop(playbook);
    let next = loop.next();
    while (!next.done) {
      const effect = next.value;
      let value: unknown;
      try {
        value = effect.type === "sleep" ? this.sleepSync(effect.ms) : this.perform(effect);
      } catch (error) {
        next = loop.throw(error);
        continue;
      }
      if (isThenable(value)) {
        throw new TypeError(`Runtime.runSync: the driver returned a Promise from ${effect.type}; use Runtime.run`);
      }
      next = loop.next(value);
    }
    return next.value;
  }

  private perform(effect: Effect<Ref, Step>): MaybePromise<unknown> {
    switch (effect.type) {
      case "read":
        return this.driver.read();
      case "act":
        return this.driver.act(effect.step, effect.ref);
      case "sleep":
        return undefined;
      default: {
        const exhaustive: never = effect;
        throw new Error(`unhandled effect: ${String(exhaustive)}`);
      }
    }
  }

  /** The single loop. Effects are yielded to a driver loop; adapter errors come back through `throw`. */
  private *loop(playbook: RuntimePlaybook<Step>): Generator<Effect<Ref, Step>, RunResult, unknown> {
    const driverName = this.driverName;
    const invalid = validatePlaybook(playbook)
      ?? (driverName === undefined
        ? { code: "unknown_driver" as const, detail: "the driver declares no kind and RuntimeOptions.driver is not set" }
        : null);
    if (invalid !== null || driverName === undefined) {
      return { status: "invalid", stopReason: null, evidence: [], stepResults: [], invalid: invalid ?? { code: "unknown_driver", detail: "" } };
    }

    const evidence: StepEvidence[] = [];
    const stepResults: StepResult[] = [];
    const finish = (status: "completed" | "stopped", stopReason: RunResult["stopReason"], stoppedAt: number): RunResult => ({
      status,
      stopReason,
      evidence,
      stepResults: stepResults.concat(
        notExecutedRest(playbook.id, driverName, playbook.steps, stoppedAt, step => this.driver.target(step)),
      ),
    });

    for (const [index, step] of playbook.steps.entries()) {
      const record = (texts: readonly string[], decision: Decision, timingMs: number): void => {
        evidence.push(this.evidenceRow(step, texts, decision));
        stepResults.push(stepResultRow({
          stepId: step.id,
          playbookId: playbook.id,
          driver: driverName,
          action: step.kind,
          decision,
          target: this.driver.target(step),
          summary: decision.note.slice(0, this.maxNoteLength),
          timingMs,
        }));
      };
      const stop = (texts: readonly string[], decision: Decision, timingMs: number): RunResult => {
        record(texts, decision, timingMs);
        return finish("stopped", decision.outcome === "ok" ? null : decision.outcome, index + 1);
      };

      const cls = this.driver.classify(step);
      const denied = requiredPermissions(step, cls.permission).find(permission => !this.permissions.allows(permission));
      if (denied !== undefined) return stop([], refused(`missing permission ${denied}`), 0);

      const startedAt = this.now();
      let snap: Snap;
      try {
        snap = (yield { type: "read" }) as Snap;
      } catch (error) {
        return stop([], driverFailed(error, "read_failed", step.kind), this.now() - startedAt);
      }

      if (cls.mutation) {
        const effect = step.effect ?? "commit";
        const gated = step.effect !== undefined || this.undeclaredMutations === "handoff";
        if (effect === "commit" && gated) return stop(this.driver.observed(snap), handoff(step.effect === undefined), 0);
      }

      let resolution = this.driver.resolve(snap, step);
      const wait = step.require?.wait ?? 0;
      const deadline = startedAt + wait;
      while (!resolution.ok && this.now() < deadline) {
        yield { type: "sleep", ms: this.pollIntervalMs };
        try {
          snap = (yield { type: "read" }) as Snap;
        } catch (error) {
          return stop([], driverFailed(error, "read_failed", step.kind), this.now() - startedAt);
        }
        resolution = this.driver.resolve(snap, step);
      }
      if (!resolution.ok) {
        return stop(this.driver.observed(snap), unmet(resolution.code, resolution.detail, wait > 0), wait > 0 ? this.now() - startedAt : 0);
      }

      const actedAt = this.now();
      try {
        yield { type: "act", step, ref: resolution.ref };
      } catch (error) {
        return stop(this.driver.observed(snap), driverFailed(error, "act_failed", step.kind), this.now() - actedAt);
      }
      record(this.driver.observed(snap), DONE, this.now() - actedAt);
    }
    return finish("completed", null, playbook.steps.length);
  }

  private evidenceRow(step: Step, texts: readonly string[], decision: Decision): StepEvidence {
    return {
      stepId: step.id,
      kind: step.kind,
      outcome: decision.outcome,
      screenTexts: texts.slice(0, this.maxEvidenceTexts).map(text => text.slice(0, this.maxEvidenceTextLength)),
      note: decision.note.slice(0, this.maxNoteLength),
    };
  }
}

function isThenable(value: unknown): boolean {
  return typeof value === "object" && value !== null && "then" in value && typeof value.then === "function";
}

/** Node allows `Atomics.wait` on the main thread; this is the sync loop's poll sleep. */
function blockingSleep(ms: number): void {
  Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, ms);
}
