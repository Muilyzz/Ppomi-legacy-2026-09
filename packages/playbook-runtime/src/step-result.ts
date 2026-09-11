/**
 * Stable per-step result for workbench timelines and LLM status.
 * Distinct from `StepEvidence` on `RunResult` (current runner log).
 * Runtimes do not emit `StepResult` yet; that is the next slice.
 */

export type StepAdapter = "page" | "os-windows" | "os-macos" | "os-android" | "phone";

export type StepAction = "focus" | "click" | "type" | "read" | "goto" | "fill" | "waitFor";

export type StepResultStatus =
  | "ok"
  | "retryable"
  | "ambiguous"
  | "protected"
  | "needs_human"
  | "failed";

/**
 * How the adapter was reached. Timeout is not "the step never ran".
 * Hybrid handoff must not treat a page `waitFor` timeout as `not_executed`.
 */
export type StepAttempt = "executed" | "timeout" | "not_executed";

/**
 * Observation-bound ref. Page locator / URL or OS accessibility name.
 * Coordinates, pixel boxes, and session node IDs are not a contract.
 */
export type StepTarget =
  | { readonly kind: "locator"; readonly locator: string }
  | { readonly kind: "url"; readonly url: string }
  | { readonly kind: "accessibility"; readonly name: string }
  | { readonly kind: "none" };

export interface StepObservation {
  readonly summary: string;
}

/** Optional screenshot paths. Overlay consumes these only when present. */
export interface Evidence {
  readonly screenshotBefore?: string;
  readonly screenshotAfter?: string;
}

export interface StepResult {
  readonly stepId: string;
  readonly playbookId: string;
  readonly adapter: StepAdapter;
  readonly action: StepAction;
  readonly status: StepResultStatus;
  readonly attempt: StepAttempt;
  readonly target: StepTarget;
  readonly observation: StepObservation;
  readonly evidence?: Evidence;
  readonly timingMs: number;
}

export class StepResultError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "StepResultError";
  }
}

const ADAPTERS = ["page", "os-windows", "os-macos", "os-android", "phone"] as const;
const ACTIONS = ["focus", "click", "type", "read", "goto", "fill", "waitFor"] as const;
const STATUSES = ["ok", "retryable", "ambiguous", "protected", "needs_human", "failed"] as const;
const ATTEMPTS = ["executed", "timeout", "not_executed"] as const;
const COORDINATE_KEYS = [
  "x",
  "y",
  "width",
  "height",
  "box",
  "bounds",
  "coordinates",
  "nodeId",
] as const;

export function parseStepResult(value: unknown): StepResult {
  if (value === null || typeof value !== "object" || Array.isArray(value)) {
    throw new StepResultError("StepResult must be an object");
  }
  const row = value as Record<string, unknown>;
  const result: StepResult = {
    stepId: requireNonEmptyString(row.stepId, "stepId"),
    playbookId: requireNonEmptyString(row.playbookId, "playbookId"),
    adapter: requireUnion(row.adapter, ADAPTERS, "adapter"),
    action: requireUnion(row.action, ACTIONS, "action"),
    status: requireUnion(row.status, STATUSES, "status"),
    attempt: requireUnion(row.attempt, ATTEMPTS, "attempt"),
    target: parseTarget(row.target),
    observation: parseObservation(row.observation),
    timingMs: parseTimingMs(row.timingMs),
  };
  if (!("evidence" in row) || row.evidence === undefined) return result;
  return { ...result, evidence: parseEvidence(row.evidence) };
}

export function parseStepResults(value: unknown): StepResult[] {
  if (!Array.isArray(value)) {
    throw new StepResultError("StepResult run must be an array");
  }
  return value.map((row, index) => {
    try {
      return parseStepResult(row);
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error);
      throw new StepResultError(`StepResult[${index}]: ${message}`);
    }
  });
}

/** JSON dump of one run (array of StepResult). Canonical field order. */
export function dumpStepResults(results: readonly StepResult[]): string {
  return `${JSON.stringify(parseStepResults(results), null, 2)}\n`;
}

export function parseStepResultsJson(json: string): StepResult[] {
  let value: unknown;
  try {
    value = JSON.parse(json);
  } catch {
    throw new StepResultError("StepResult JSON is not valid JSON");
  }
  return parseStepResults(value);
}

function parseTarget(value: unknown): StepTarget {
  if (value === null || typeof value !== "object" || Array.isArray(value)) {
    throw new StepResultError("target must be an observation-bound ref object");
  }
  const row = value as Record<string, unknown>;
  const forbidden = COORDINATE_KEYS.filter(key => key in row);
  if (forbidden.length > 0) {
    throw new StepResultError(
      `target must not use coordinates or session geometry (${forbidden.join(", ")})`,
    );
  }

  switch (row.kind) {
    case "locator":
      return { kind: "locator", locator: requireNonEmptyString(row.locator, "target.locator") };
    case "url":
      return { kind: "url", url: requireNonEmptyString(row.url, "target.url") };
    case "accessibility":
      return { kind: "accessibility", name: requireNonEmptyString(row.name, "target.name") };
    case "none":
      return { kind: "none" };
    default:
      throw new StepResultError("target.kind must be locator | url | accessibility | none");
  }
}

function parseObservation(value: unknown): StepObservation {
  if (value === null || typeof value !== "object" || Array.isArray(value)) {
    throw new StepResultError("observation must be an object");
  }
  const row = value as Record<string, unknown>;
  if (typeof row.summary !== "string") {
    throw new StepResultError("observation.summary must be a string");
  }
  return { summary: row.summary };
}

function parseEvidence(value: unknown): Evidence {
  if (value === null || typeof value !== "object" || Array.isArray(value)) {
    throw new StepResultError("evidence must be an object");
  }
  const row = value as Record<string, unknown>;
  const evidence: {
    screenshotBefore?: string;
    screenshotAfter?: string;
  } = {};
  if ("screenshotBefore" in row && row.screenshotBefore !== undefined) {
    evidence.screenshotBefore = requireNonEmptyString(row.screenshotBefore, "evidence.screenshotBefore");
  }
  if ("screenshotAfter" in row && row.screenshotAfter !== undefined) {
    evidence.screenshotAfter = requireNonEmptyString(row.screenshotAfter, "evidence.screenshotAfter");
  }
  return evidence;
}

function parseTimingMs(value: unknown): number {
  if (typeof value !== "number" || !Number.isFinite(value) || value < 0) {
    throw new StepResultError("timingMs must be a non-negative finite number");
  }
  return value;
}

function requireNonEmptyString(value: unknown, label: string): string {
  if (typeof value !== "string" || value.length === 0) {
    throw new StepResultError(`${label} must be a non-empty string`);
  }
  return value;
}

function requireUnion<T extends string>(
  value: unknown,
  allowed: readonly T[],
  label: string,
): T {
  if (typeof value === "string") {
    for (const option of allowed) {
      if (option === value) return option;
    }
  }
  throw new StepResultError(`${label} must be ${allowed.join(" | ")}`);
}
