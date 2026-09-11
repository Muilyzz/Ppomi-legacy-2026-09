/**
 * Stable per-step result for workbench timelines and LLM status.
 * Distinct from `StepEvidence` on `RunResult` (current runner log).
 * Runtimes emit one `StepResult` per declared step on `RunResult.stepResults`.
 *
 * Imported from #17 / #18 (d73773b / ce87993) with these additive changes,
 * proposed back to #17: `driver` is the primary field (#22 glossary) and the
 * parser accepts `adapter` as a deprecated input alias; `code?` carries
 * structured runtime / executor codes; `observation.summary` is bounded;
 * `target` keys are a whitelist and `target.url` is origin + pathname only.
 */

export type StepDriver = "page" | "os-windows" | "os-macos" | "os-android" | "phone";
/** @deprecated Renamed to `StepDriver` (#22 glossary). */
export type StepAdapter = StepDriver;

export type StepAction = "focus" | "click" | "type" | "read" | "goto" | "fill" | "waitFor";

export type StepResultStatus =
  | "ok"
  | "retryable"
  | "ambiguous"
  | "protected"
  | "needs_human"
  | "failed";

/**
 * How the driver was reached. Timeout is not "the step never ran".
 * Hybrid handoff must not treat a page `waitFor` timeout as `not_executed`.
 */
export type StepAttempt = "executed" | "timeout" | "not_executed";

/**
 * Observation-bound ref. Page locator / URL or OS accessibility name.
 * Coordinates, pixel boxes, and session node IDs are not a contract.
 * `url` is origin + pathname only; `role` is the optional accessibility role.
 */
export type StepTarget =
  | { readonly kind: "locator"; readonly locator: string }
  | { readonly kind: "url"; readonly url: string }
  | { readonly kind: "accessibility"; readonly name: string; readonly role?: string }
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
  /** `adapter` is accepted as a deprecated input alias by `parseStepResult`; rows carry `driver` only. */
  readonly driver: StepDriver;
  readonly action: StepAction;
  readonly status: StepResultStatus;
  readonly attempt: StepAttempt;
  /** Structured runtime or executor code (`permission_denied`, `stale_screen`, `protected_action`, `navigation_refused`, …); never prose. */
  readonly code?: string;
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

const DRIVERS = ["page", "os-windows", "os-macos", "os-android", "phone"] as const;
const ACTIONS = ["focus", "click", "type", "read", "goto", "fill", "waitFor"] as const;
const STATUSES = ["ok", "retryable", "ambiguous", "protected", "needs_human", "failed"] as const;
const ATTEMPTS = ["executed", "timeout", "not_executed"] as const;
/** The only keys a target may carry. Anything else (x/y, box, nodeId, rect, …) is rejected, not dropped. */
const TARGET_KEYS = ["kind", "locator", "url", "name", "role"] as const;
const MAX_SUMMARY_LENGTH = 2048;
const SUMMARY_MARKER = " …[truncated]";

export function parseStepResult(value: unknown): StepResult {
  if (value === null || typeof value !== "object" || Array.isArray(value)) {
    throw new StepResultError("StepResult must be an object");
  }
  const row = value as Record<string, unknown>;
  const result: StepResult = {
    stepId: requireNonEmptyString(row.stepId, "stepId"),
    playbookId: requireNonEmptyString(row.playbookId, "playbookId"),
    driver: requireUnion(row.driver ?? row.adapter, DRIVERS, "driver"),
    action: requireUnion(row.action, ACTIONS, "action"),
    status: requireUnion(row.status, STATUSES, "status"),
    attempt: requireUnion(row.attempt, ATTEMPTS, "attempt"),
    target: parseTarget(row.target),
    observation: parseObservation(row.observation),
    timingMs: parseTimingMs(row.timingMs),
  };
  const withCode = "code" in row && row.code !== undefined
    ? { ...result, code: requireNonEmptyString(row.code, "code") }
    : result;
  if (!("evidence" in row) || row.evidence === undefined) return withCode;
  return { ...withCode, evidence: parseEvidence(row.evidence) };
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

/** JSON dump of one run (array of StepResult). Canonical field order; `driver` only, never `adapter`. */
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
  const unknown = Object.keys(row).filter(key => !TARGET_KEYS.some(allowed => allowed === key));
  if (unknown.length > 0) {
    throw new StepResultError(
      `target must not use coordinates or session geometry; unknown keys (${unknown.join(", ")}), allowed: ${TARGET_KEYS.join(", ")}`,
    );
  }

  switch (row.kind) {
    case "locator":
      return { kind: "locator", locator: requireNonEmptyString(row.locator, "target.locator") };
    case "url":
      return { kind: "url", url: requirePublicUrl(requireNonEmptyString(row.url, "target.url")) };
    case "accessibility": {
      const name = requireNonEmptyString(row.name, "target.name");
      if (!("role" in row) || row.role === undefined) return { kind: "accessibility", name };
      return { kind: "accessibility", name, role: requireNonEmptyString(row.role, "target.role") };
    }
    case "none":
      return { kind: "none" };
    default:
      throw new StepResultError("target.kind must be locator | url | accessibility | none");
  }
}

/** Absolute, credential-free, and nothing after the path: query strings and fragments carry tokens. */
function requirePublicUrl(url: string): string {
  let parsed: URL;
  try {
    parsed = new URL(url);
  } catch {
    throw new StepResultError("target.url must be an absolute URL");
  }
  if (parsed.username !== "" || parsed.password !== "" || parsed.search !== "" || parsed.hash !== "") {
    throw new StepResultError("target.url must be origin + pathname only, without credentials, query or fragment");
  }
  return url;
}

function parseObservation(value: unknown): StepObservation {
  if (value === null || typeof value !== "object" || Array.isArray(value)) {
    throw new StepResultError("observation must be an object");
  }
  const row = value as Record<string, unknown>;
  if (typeof row.summary !== "string") {
    throw new StepResultError("observation.summary must be a string");
  }
  const summary = row.summary.length > MAX_SUMMARY_LENGTH
    ? `${row.summary.slice(0, MAX_SUMMARY_LENGTH - SUMMARY_MARKER.length)}${SUMMARY_MARKER}`
    : row.summary;
  return { summary };
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
