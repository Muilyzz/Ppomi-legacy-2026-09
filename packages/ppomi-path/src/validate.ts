import { PathError } from "./errors.ts";
import {
  PATH_EFFECTS,
  PATH_ID_PATTERN,
  PATH_PERMISSIONS,
  PATH_SCHEMA_VERSION,
  PATH_STEP_KINDS,
  PATH_SURFACES,
  PATH_VERSION_PATTERN,
  type PathCatalog,
  type PathCatalogEntry,
  type PathDocument,
  type PathEffect,
  type PathPermission,
  type PathStep,
  type PathStepKind,
  type PathStepRequirement,
  type PathSurface,
} from "./schema.ts";

const CATALOG_KEYS = ["schemaVersion", "paths"] as const;
const ENTRY_KEYS = ["id", "version", "href"] as const;
const DOCUMENT_KEYS = [
  "schemaVersion",
  "id",
  "version",
  "title",
  "surface",
  "legacyPackage",
  "allowedOrigins",
  "steps",
] as const;
const STEP_KEYS = ["id", "title", "kind", "target", "locator", "url", "text", "effect", "require"] as const;
const REQUIRE_KEYS = ["permission", "screen", "focused", "url", "locator", "text", "wait"] as const;

export function validatePathCatalog(value: unknown): PathCatalog {
  const record = asObject(value, "path catalog");
  assertKeys(record, CATALOG_KEYS, "path catalog");
  const schemaVersion = record.schemaVersion;
  if (schemaVersion !== PATH_SCHEMA_VERSION) {
    throw new PathError("schema_version", `path catalog schemaVersion must be ${PATH_SCHEMA_VERSION}`);
  }
  if (!Array.isArray(record.paths)) {
    throw new PathError("catalog_paths", "path catalog paths must be an array");
  }
  return {
    schemaVersion: PATH_SCHEMA_VERSION,
    paths: record.paths.map((entry, index) => validateCatalogEntry(entry, index)),
  };
}

export function validatePathDocument(value: unknown): PathDocument {
  const record = asObject(value, "path document");
  assertKeys(record, DOCUMENT_KEYS, "path document");
  if (record.schemaVersion !== PATH_SCHEMA_VERSION) {
    throw new PathError("schema_version", `path document schemaVersion must be ${PATH_SCHEMA_VERSION}`);
  }
  const id = asId(record.id, "path document id");
  const version = asVersion(record.version, "path document version");
  const title = asNonEmptyString(record.title, "path document title");
  const surface = asSurface(record.surface);
  if (!Array.isArray(record.steps) || record.steps.length === 0) {
    throw new PathError("steps", "path document steps must be a non-empty array");
  }
  const document: PathDocument = {
    schemaVersion: PATH_SCHEMA_VERSION,
    id,
    version,
    title,
    surface,
    steps: record.steps.map((step, index) => validateStep(step, index)),
  };
  const withLegacy =
    record.legacyPackage === undefined
      ? document
      : { ...document, legacyPackage: asNonEmptyString(record.legacyPackage, "path document legacyPackage") };
  if (record.allowedOrigins === undefined) return withLegacy;
  return {
    ...withLegacy,
    allowedOrigins: asOriginList(record.allowedOrigins, "path document allowedOrigins"),
  };
}

function validateCatalogEntry(value: unknown, index: number): PathCatalogEntry {
  const record = asObject(value, `path catalog entry ${index}`);
  assertKeys(record, ENTRY_KEYS, `path catalog entry ${index}`);
  return {
    id: asId(record.id, `path catalog entry ${index} id`),
    version: asVersion(record.version, `path catalog entry ${index} version`),
    href: asHref(record.href, `path catalog entry ${index} href`),
  };
}

function validateStep(value: unknown, index: number): PathStep {
  const record = asObject(value, `path step ${index}`);
  assertKeys(record, STEP_KEYS, `path step ${index}`);
  const id = asId(record.id, `path step ${index} id`);
  const kind = asStepKind(record.kind, index);
  const step: PathStep = { id, kind };
  const withTitle =
    record.title === undefined
      ? step
      : { ...step, title: asNonEmptyString(record.title, `path step ${index} title`) };
  const withTarget =
    record.target === undefined
      ? withTitle
      : { ...withTitle, target: asNonEmptyString(record.target, `path step ${index} target`) };
  const withLocator =
    record.locator === undefined
      ? withTarget
      : { ...withTarget, locator: asNonEmptyString(record.locator, `path step ${index} locator`) };
  const withUrl =
    record.url === undefined
      ? withLocator
      : { ...withLocator, url: asNonEmptyString(record.url, `path step ${index} url`) };
  const withText =
    record.text === undefined
      ? withUrl
      : { ...withUrl, text: asNonEmptyString(record.text, `path step ${index} text`) };
  const withEffect =
    record.effect === undefined
      ? withText
      : { ...withText, effect: asEffect(record.effect, index) };
  const complete =
    record.require === undefined
      ? withEffect
      : { ...withEffect, require: validateRequirement(record.require, index) };
  return requireTargetForKind(complete, index);
}

function validateRequirement(value: unknown, index: number): PathStepRequirement {
  const record = asObject(value, `path step ${index} require`);
  assertKeys(record, REQUIRE_KEYS, `path step ${index} require`);
  const require: PathStepRequirement = {};
  const withPermission =
    record.permission === undefined
      ? require
      : { ...require, permission: asPermission(record.permission, index) };
  const withScreen =
    record.screen === undefined
      ? withPermission
      : { ...withPermission, screen: asStringList(record.screen, `path step ${index} require.screen`) };
  const withFocused =
    record.focused === undefined
      ? withScreen
      : { ...withScreen, focused: asNonEmptyString(record.focused, `path step ${index} require.focused`) };
  const withUrl =
    record.url === undefined
      ? withFocused
      : { ...withFocused, url: asNonEmptyString(record.url, `path step ${index} require.url`) };
  const withLocator =
    record.locator === undefined
      ? withUrl
      : { ...withUrl, locator: asNonEmptyString(record.locator, `path step ${index} require.locator`) };
  const withText =
    record.text === undefined
      ? withLocator
      : { ...withLocator, text: asStringList(record.text, `path step ${index} require.text`) };
  if (record.wait === undefined) return withText;
  return { ...withText, wait: asWaitMs(record.wait, index) };
}

function requireTargetForKind(step: PathStep, index: number): PathStep {
  switch (step.kind) {
    case "payment":
    case "submit":
      if (step.target === undefined) {
        throw new PathError(
          "step_target",
          `path step ${index} (${step.id}) kind ${step.kind} needs a target`,
        );
      }
      return step;
    case "focus":
    case "click":
    case "type":
    case "read":
    case "goto":
    case "fill":
    case "waitFor":
    case "human":
      return step;
    default: {
      const exhaustive: never = step.kind;
      throw new PathError("step_kind", `unhandled path step kind: ${String(exhaustive)}`);
    }
  }
}

function asSurface(value: unknown): PathSurface {
  if (typeof value !== "string" || !isPathSurface(value)) {
    throw new PathError("surface", `path document surface must be one of ${PATH_SURFACES.join(", ")}`);
  }
  return value;
}

function isPathSurface(value: string): value is PathSurface {
  return (PATH_SURFACES as readonly string[]).includes(value);
}

function asStepKind(value: unknown, index: number): PathStepKind {
  if (typeof value !== "string" || !isPathStepKind(value)) {
    throw new PathError(
      "step_kind",
      `path step ${index} kind must be one of ${PATH_STEP_KINDS.join(", ")}`,
    );
  }
  return value;
}

function isPathStepKind(value: string): value is PathStepKind {
  return (PATH_STEP_KINDS as readonly string[]).includes(value);
}

function asPermission(value: unknown, index: number): PathPermission {
  if (typeof value !== "string" || !isPathPermission(value)) {
    throw new PathError(
      "permission",
      `path step ${index} require.permission must be one of ${PATH_PERMISSIONS.join(", ")}`,
    );
  }
  return value;
}

function isPathPermission(value: string): value is PathPermission {
  return (PATH_PERMISSIONS as readonly string[]).includes(value);
}

function asEffect(value: unknown, index: number): PathEffect {
  if (typeof value !== "string" || !isPathEffect(value)) {
    throw new PathError(
      "effect",
      `path step ${index} effect must be one of ${PATH_EFFECTS.join(", ")}`,
    );
  }
  switch (value) {
    case "navigate":
    case "input":
    case "commit":
      return value;
    default: {
      const exhaustive: never = value;
      throw new PathError("effect", `unhandled path step effect: ${String(exhaustive)}`);
    }
  }
}

function isPathEffect(value: string): value is PathEffect {
  return (PATH_EFFECTS as readonly string[]).includes(value);
}

function asWaitMs(value: unknown, index: number): number {
  if (typeof value !== "number" || !Number.isInteger(value) || value <= 0) {
    throw new PathError("wait", `path step ${index} require.wait must be a positive integer (ms)`);
  }
  return value;
}

function asOriginList(value: unknown, label: string): readonly string[] {
  if (!Array.isArray(value) || value.length === 0) {
    throw new PathError("allowed_origins", `${label} must be a non-empty string array`);
  }
  return value.map((item, index) => asOrigin(item, `${label}[${index}]`));
}

function asOrigin(value: unknown, label: string): string {
  const text = asNonEmptyString(value, label);
  let parsed: URL;
  try {
    parsed = new URL(text);
  } catch {
    throw new PathError("origin", `${label} must be an http(s) origin`);
  }
  if (parsed.protocol !== "http:" && parsed.protocol !== "https:") {
    throw new PathError("origin", `${label} must be an http(s) origin`);
  }
  if (parsed.username !== "" || parsed.password !== "" || parsed.search !== "" || parsed.hash !== "") {
    throw new PathError("origin", `${label} must be an origin only (no credentials, query, or fragment)`);
  }
  if (parsed.pathname !== "/" && parsed.pathname !== "") {
    throw new PathError("origin", `${label} must be an origin only (no path)`);
  }
  return parsed.origin;
}

function asObject(value: unknown, label: string): Record<string, unknown> {
  if (value === null || typeof value !== "object" || Array.isArray(value)) {
    throw new PathError("type", `${label} must be an object`);
  }
  return value as Record<string, unknown>;
}

function assertKeys(
  record: Record<string, unknown>,
  allowed: readonly string[],
  label: string,
): void {
  for (const key of Object.keys(record)) {
    if (!allowed.includes(key)) {
      throw new PathError("unknown_field", `${label} has unknown field ${key}`);
    }
  }
}

function asId(value: unknown, label: string): string {
  const text = asNonEmptyString(value, label);
  if (!PATH_ID_PATTERN.test(text)) {
    throw new PathError("id", `${label} must match ${PATH_ID_PATTERN}`);
  }
  return text;
}

function asVersion(value: unknown, label: string): string {
  const text = asNonEmptyString(value, label);
  if (!PATH_VERSION_PATTERN.test(text)) {
    throw new PathError("version", `${label} must be a three-part version like 0.1.0`);
  }
  return text;
}

function asHref(value: unknown, label: string): string {
  const text = asNonEmptyString(value, label);
  if (text.startsWith("/") || text.includes("..") || text.includes("\\") || text.includes(":")) {
    throw new PathError("href", `${label} must be a relative catalog path without '..'`);
  }
  return text;
}

function asNonEmptyString(value: unknown, label: string): string {
  if (typeof value !== "string" || value.trim().length === 0) {
    throw new PathError("string", `${label} must be a non-empty string`);
  }
  return value;
}

function asStringList(value: unknown, label: string): readonly string[] {
  if (!Array.isArray(value) || value.length === 0 || value.some(item => typeof item !== "string" || item.length === 0)) {
    throw new PathError("string_list", `${label} must be a non-empty string array`);
  }
  return value;
}
