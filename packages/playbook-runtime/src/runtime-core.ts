import { isAdapterTimeout } from "./adapter-timeout.ts";
import { emitNotExecutedRest, emitStepResult } from "./emit-step-result.ts";
import type { PermissionGate } from "./permissions.ts";
import type {
  MaybePromise,
  PageStepKind,
  Permission,
  RunResult,
  StepEffect,
  StepEvidence,
  StepKind,
  StepOutcome,
  SurfaceKind,
} from "./playbook.ts";
import type { StepAdapter, StepAttempt, StepResult, StepResultStatus, StepTarget } from "./step-result.ts";

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
  /** Mutations need a declared `effect`; without one the core hands them off, never runs them. */
  readonly mutation: boolean;
}

/** Reasons the runtime itself reports. Adapter failures carry the adapter's own code instead. */
export type RuntimeCode =
  | "missing_permission"
  | "no_effect"
  | "commit"
  | "read_failed"
  | "act_failed"
  | "screen_missing"
  | "focus_mismatch"
  | "target_required"
  | "target_not_on_screen"
  | "text_required"
  | "origin_not_declared"
  | "url_mismatch"
  | "page_missing"
  | "locator_required"
  | "locator_not_on_page"
  | "url_required"
  | "navigation_refused";

export type Resolution<Ref> =
  | { readonly ok: true; readonly ref: Ref }
  | { readonly ok: false; readonly code: RuntimeCode; readonly detail: string };

/**
 * One observable surface (OS screen, web page). The core owns permissions,
 * effect gating, polling, results and failure handling; a surface only reads,
 * resolves declared targets against a snapshot, and acts on a resolved target.
 * `read` and `act` may be sync or async; `Runtime.run` awaits them and
 * `Runtime.runSync` requires them to be sync.
 */
export interface Surface<Snap, Ref, Step extends RuntimeStep> {
  readonly kind: SurfaceKind;
  /** Which adapter family this surface drives, copied onto every `StepResult`. */
  readonly adapter: StepAdapter;
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

type Effect<Ref, Step> =
  | { readonly type: "read" }
  | { readonly type: "act"; readonly step: Step; readonly ref: Ref }
  | { readonly type: "sleep"; readonly ms: number };

interface Decision {
  readonly outcome: StepOutcome;
  readonly status: StepResultStatus;
  readonly attempt: StepAttempt;
  readonly note: string;
}

/**
 * Runs declared steps against one surface. Fail-closed at every gate: a missing
 * permission, an undeclared or `commit` effect, an unmet precondition after the
 * declared wait, or an adapter failure stops the run with an evidence row and a
 * `StepResult`, marks the remaining steps `not_executed`, and sends nothing
 * further to the adapter. `completed` means the declared steps finished; it is
 * not a business-result claim.
 */
export class Runtime<Snap, Ref, Step extends RuntimeStep> {
  private readonly surface: Surface<Snap, Ref, Step>;
  private readonly permissions: PermissionGate;
  private readonly undeclaredMutations: "handoff" | "run";
  private readonly pollIntervalMs: number;
  private readonly maxEvidenceTexts: number;
  private readonly maxEvidenceTextLength: number;
  private readonly maxNoteLength: number;
  private readonly sleep: (ms: number) => Promise<void>;
  private readonly sleepSync: (ms: number) => void;
  private readonly now: () => number;

  constructor(surface: Surface<Snap, Ref, Step>, permissions: PermissionGate, options: RuntimeOptions = {}) {
    this.surface = surface;
    this.permissions = permissions;
    this.undeclaredMutations = options.undeclaredMutations ?? "handoff";
    this.pollIntervalMs = options.pollIntervalMs ?? DEFAULTS.pollIntervalMs;
    this.maxEvidenceTexts = options.maxEvidenceTexts ?? DEFAULTS.maxEvidenceTexts;
    this.maxEvidenceTextLength = options.maxEvidenceTextLength ?? DEFAULTS.maxEvidenceTextLength;
    this.maxNoteLength = options.maxNoteLength ?? DEFAULTS.maxNoteLength;
    this.sleep = options.sleep ?? (ms => new Promise(resolve => setTimeout(resolve, ms)));
    this.sleepSync = options.sleepSync ?? blockingSleep;
    this.now = options.now ?? (() => Date.now());
  }

  /** Async driver: awaits every adapter call. Use this for real adapters. */
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

  /** Sync driver for sync adapters (fixtures, UIA/AX bridges that block). Throws on a Promise-returning adapter. */
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
        throw new TypeError(`Runtime.runSync: the adapter returned a Promise from ${effect.type}; use Runtime.run`);
      }
      next = loop.next(value);
    }
    return next.value;
  }

  private perform(effect: Effect<Ref, Step>): MaybePromise<unknown> {
    switch (effect.type) {
      case "read":
        return this.surface.read();
      case "act":
        return this.surface.act(effect.step, effect.ref);
      case "sleep":
        return undefined;
      default: {
        const exhaustive: never = effect;
        throw new Error(`unhandled effect: ${String(exhaustive)}`);
      }
    }
  }

  /** The single loop. Effects are yielded to a driver; adapter errors come back through `throw`. */
  private *loop(playbook: RuntimePlaybook<Step>): Generator<Effect<Ref, Step>, RunResult, unknown> {
    const evidence: StepEvidence[] = [];
    const stepResults: StepResult[] = [];
    const finish = (status: RunResult["status"], stopReason: RunResult["stopReason"], stoppedAt: number): RunResult => ({
      status,
      stopReason,
      evidence,
      stepResults: stepResults.concat(
        emitNotExecutedRest(playbook.id, this.surface.adapter, playbook.steps, stoppedAt, step => this.surface.target(step)),
      ),
    });

    for (const [index, step] of playbook.steps.entries()) {
      const record = (texts: readonly string[], decision: Decision, timingMs: number): void => {
        evidence.push(this.evidenceRow(step, texts, decision));
        stepResults.push(this.stepResult(playbook.id, step, decision, timingMs));
      };
      const stop = (texts: readonly string[], decision: Decision, timingMs: number): RunResult => {
        record(texts, decision, timingMs);
        return finish("stopped", decision.outcome === "ok" ? null : decision.outcome, index + 1);
      };

      const cls = this.surface.classify(step);
      const denied = requiredPermissions(step, cls.permission).find(permission => !this.permissions.allows(permission));
      if (denied !== undefined) return stop([], refused(`missing permission ${denied}`), 0);

      const startedAt = this.now();
      let snap: Snap;
      try {
        snap = (yield { type: "read" }) as Snap;
      } catch (error) {
        return stop([], adapterFailed(error), this.now() - startedAt);
      }

      if (cls.mutation) {
        const effect = step.effect ?? "commit";
        const gated = step.effect !== undefined || this.undeclaredMutations === "handoff";
        if (effect === "commit" && gated) return stop(this.surface.observed(snap), handoff(step.effect === undefined), 0);
      }

      let resolution = this.surface.resolve(snap, step);
      const wait = step.require?.wait ?? 0;
      const deadline = startedAt + wait;
      while (!resolution.ok && this.now() < deadline) {
        yield { type: "sleep", ms: this.pollIntervalMs };
        try {
          snap = (yield { type: "read" }) as Snap;
        } catch (error) {
          return stop([], adapterFailed(error), this.now() - startedAt);
        }
        resolution = this.surface.resolve(snap, step);
      }
      if (!resolution.ok) {
        return stop(this.surface.observed(snap), unmet(resolution.code, resolution.detail, wait > 0), wait > 0 ? this.now() - startedAt : 0);
      }

      const actedAt = this.now();
      try {
        yield { type: "act", step, ref: resolution.ref };
      } catch (error) {
        return stop(this.surface.observed(snap), adapterFailed(error), this.now() - actedAt);
      }
      record(this.surface.observed(snap), DONE, this.now() - actedAt);
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

  private stepResult(playbookId: string, step: Step, decision: Decision, timingMs: number): StepResult {
    return emitStepResult({
      stepId: step.id,
      playbookId,
      adapter: this.surface.adapter,
      action: step.kind,
      status: decision.status,
      attempt: decision.attempt,
      target: this.surface.target(step),
      summary: decision.note.slice(0, this.maxNoteLength),
      timingMs: Math.max(0, timingMs),
    });
  }
}

const DONE: Decision = { outcome: "ok", status: "ok", attempt: "executed", note: "step finished" };

function refused(note: string): Decision {
  return { outcome: "permission_denied", status: "protected", attempt: "not_executed", note };
}

function handoff(undeclared: boolean): Decision {
  return {
    outcome: "handoff",
    status: "needs_human",
    attempt: "not_executed",
    note: undeclared ? "no declared effect: the person takes this step" : "commit step: the person takes this step",
  };
}

/** Still unmet after a declared wait is a timeout; a policy refusal is protected; otherwise the screen did not match. */
function unmet(code: RuntimeCode, detail: string, waited: boolean): Decision {
  if (waited) return { outcome: "precondition_failed", status: "retryable", attempt: "timeout", note: detail };
  switch (code) {
    case "origin_not_declared":
    case "navigation_refused":
      return { outcome: "precondition_failed", status: "protected", attempt: "not_executed", note: detail };
    case "screen_missing":
    case "focus_mismatch":
    case "target_required":
    case "target_not_on_screen":
    case "text_required":
    case "url_mismatch":
    case "page_missing":
    case "locator_required":
    case "locator_not_on_page":
    case "url_required":
    case "missing_permission":
    case "no_effect":
    case "commit":
    case "read_failed":
    case "act_failed":
      return { outcome: "precondition_failed", status: "failed", attempt: "not_executed", note: detail };
    default: {
      const exhaustive: never = code;
      return { outcome: "precondition_failed", status: "failed", attempt: "not_executed", note: String(exhaustive) };
    }
  }
}

/** The adapter was reached and threw. Timeouts are retryable; an executor refusal keeps its meaning. */
function adapterFailed(error: unknown): Decision {
  const note = error instanceof Error ? error.message : String(error);
  if (isAdapterTimeout(error)) return { outcome: "timeout", status: "retryable", attempt: "timeout", note };
  switch (codeOf(error)) {
    case "stale_screen":
      return { outcome: "failed", status: "retryable", attempt: "executed", note };
    case "protected_action":
      return { outcome: "failed", status: "protected", attempt: "executed", note };
    default:
      return { outcome: "failed", status: "failed", attempt: "executed", note };
  }
}

function codeOf(error: unknown): string | null {
  if (error instanceof Error && "code" in error && typeof error.code === "string") return error.code;
  return null;
}

function isThenable(value: unknown): boolean {
  return typeof value === "object" && value !== null && "then" in value && typeof value.then === "function";
}

/** Node allows `Atomics.wait` on the main thread; this is the sync driver's poll sleep. */
function blockingSleep(ms: number): void {
  Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, ms);
}
