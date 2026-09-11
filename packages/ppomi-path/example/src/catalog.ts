import { lstat, readFile } from "node:fs/promises";
import path from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

export const PATH_KINDS = [
  "open",
  "focus",
  "click",
  "type",
  "read",
  "human",
  "payment",
  "submit",
] as const;

export const BODY_KINDS = [
  "macos",
  "windows",
  "android",
  "iphone-mirroring",
  "playwright",
] as const;

export const GRANTS = ["ui.read", "ui.control"] as const;

export type PathKind = (typeof PATH_KINDS)[number];
export type BodyKind = (typeof BODY_KINDS)[number];
export type Grant = (typeof GRANTS)[number];
export type FinancialSubmit = false | "human";

const STABLE_ID = /^[a-z][a-z0-9-]{0,63}$/;
const SEMVER = /^[0-9]+\.[0-9]+\.[0-9]+(?:-[0-9A-Za-z.-]+)?(?:\+[0-9A-Za-z.-]+)?$/;

export interface PathStep {
  readonly id: string;
  readonly kind: PathKind;
  readonly title: string;
  readonly target?: string;
}

export interface PathDefinition {
  readonly id: string;
  readonly title: string;
  readonly bodyKind: BodyKind;
  readonly grant: Grant;
  readonly financialSubmit: FinancialSubmit;
  readonly steps: readonly PathStep[];
}

export interface PathCatalog {
  readonly schemaVersion: 1;
  readonly catalogId: string;
  readonly version: string;
  readonly paths: readonly PathDefinition[];
}

export class CatalogError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "CatalogError";
  }
}

function requireValue(condition: unknown, reason: string): asserts condition {
  if (!condition) throw new CatalogError(reason);
}

function isObject(value: unknown): value is Record<string, unknown> {
  return value !== null && typeof value === "object" && !Array.isArray(value);
}

function fullMatch(value: unknown, expression: RegExp): value is string {
  return typeof value === "string" && value.match(expression)?.[0] === value;
}

function isPathKind(value: unknown): value is PathKind {
  return typeof value === "string" && (PATH_KINDS as readonly string[]).includes(value);
}

function isBodyKind(value: unknown): value is BodyKind {
  return typeof value === "string" && (BODY_KINDS as readonly string[]).includes(value);
}

function isGrant(value: unknown): value is Grant {
  return typeof value === "string" && (GRANTS as readonly string[]).includes(value);
}

function validateStep(step: unknown, pathId: string, seen: Set<string>): PathStep {
  requireValue(isObject(step), `path ${pathId}: step must be an object`);
  requireValue(fullMatch(step.id, STABLE_ID), `path ${pathId}: step id`);
  requireValue(!seen.has(step.id), `path ${pathId}: duplicate step ${step.id}`);
  seen.add(step.id);
  requireValue(isPathKind(step.kind), `path ${pathId} step ${step.id}: kind`);
  requireValue(typeof step.title === "string" && step.title.trim().length > 0, `path ${pathId} step ${step.id}: title`);
  if (step.kind === "payment" || step.kind === "submit") {
    requireValue(typeof step.target === "string" && step.target.length > 0, `path ${pathId} step ${step.id}: ${step.kind} needs target`);
  }
  const target = typeof step.target === "string" ? step.target : undefined;
  return {
    id: step.id,
    kind: step.kind,
    title: step.title,
    ...(target !== undefined ? { target } : {}),
  };
}

function validatePath(value: unknown, seen: Set<string>): PathDefinition {
  requireValue(isObject(value), "path must be an object");
  requireValue(fullMatch(value.id, STABLE_ID), "path id");
  requireValue(!seen.has(value.id), `duplicate path ${value.id}`);
  seen.add(value.id);
  requireValue(typeof value.title === "string" && value.title.trim().length > 0, `path ${value.id}: title`);
  requireValue(isBodyKind(value.bodyKind), `path ${value.id}: bodyKind`);
  requireValue(isGrant(value.grant), `path ${value.id}: grant`);
  requireValue(value.financialSubmit === false || value.financialSubmit === "human", `path ${value.id}: financialSubmit`);
  requireValue(Array.isArray(value.steps) && value.steps.length > 0, `path ${value.id}: steps`);
  const stepIds = new Set<string>();
  const steps = value.steps.map(step => validateStep(step, value.id, stepIds));
  return {
    id: value.id,
    title: value.title,
    bodyKind: value.bodyKind,
    grant: value.grant,
    financialSubmit: value.financialSubmit,
    steps,
  };
}

export function validatePathCatalog(value: unknown): PathCatalog {
  requireValue(isObject(value), "catalog must be an object");
  requireValue(value.schemaVersion === 1, "schemaVersion must be 1");
  requireValue(fullMatch(value.catalogId, STABLE_ID), "catalogId");
  requireValue(fullMatch(value.version, SEMVER), "semantic version");
  requireValue(Array.isArray(value.paths) && value.paths.length > 0, "paths");
  const seen = new Set<string>();
  return {
    schemaVersion: 1,
    catalogId: value.catalogId,
    version: value.version,
    paths: value.paths.map(entry => validatePath(entry, seen)),
  };
}

export async function loadPathCatalogFile(filePath: string): Promise<PathCatalog> {
  const text = await readFile(filePath, "utf8");
  return validatePathCatalog(JSON.parse(text));
}

export interface LegacyPlaybookSummary {
  readonly id: string;
  readonly name: string;
  readonly version: string;
  readonly capabilities: number;
}

export interface LegacyCatalogSummary {
  readonly schemaVersion: 1;
  readonly root: string;
  readonly playbooks: readonly LegacyPlaybookSummary[];
}

export async function loadLegacyCatalog(root: string): Promise<LegacyCatalogSummary> {
  const stat = await lstat(root);
  requireValue(stat.isDirectory() && !stat.isSymbolicLink(), `legacy catalog is not a directory: ${root}`);
  const hubPath = fileURLToPath(new URL("../../../../hub/lib/catalog.js", import.meta.url));
  const hub = await import(pathToFileURL(hubPath).href) as {
    readCatalog: (catalogRoot?: string) => Promise<{
      schemaVersion: number;
      playbooks: readonly { manifest: { id: string; name: string; version: string; capabilities: readonly unknown[] } }[];
    }>;
  };
  const catalog = await hub.readCatalog(root);
  return {
    schemaVersion: 1,
    root,
    playbooks: catalog.playbooks.map(({ manifest }) => ({
      id: manifest.id,
      name: manifest.name,
      version: manifest.version,
      capabilities: manifest.capabilities.length,
    })),
  };
}

export async function findRepoCatalogRoot(startDir: string): Promise<string | null> {
  let current = path.resolve(startDir);
  for (let i = 0; i < 8; i += 1) {
    const candidate = path.join(current, "Ppomi", "Sources", "Ppomi", "Catalog");
    try {
      const stat = await lstat(candidate);
      if (stat.isDirectory()) return candidate;
    } catch {
      // keep walking
    }
    const parent = path.dirname(current);
    if (parent === current) break;
    current = parent;
  }
  return null;
}
