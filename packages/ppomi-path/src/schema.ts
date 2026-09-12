export const PATH_SCHEMA_VERSION = 1 as const;

export const PATH_SURFACES = [
  "os-windows",
  "os-macos",
  "os-android",
  "iphone-mirroring",
  "page",
] as const;

export type PathSurface = (typeof PATH_SURFACES)[number];

export const PATH_PERMISSIONS = ["ui.read", "ui.control"] as const;

export type PathPermission = (typeof PATH_PERMISSIONS)[number];

export const PATH_STEP_KINDS = [
  "focus",
  "click",
  "type",
  "read",
  "key",
  "goto",
  "fill",
  "waitFor",
  "human",
  "payment",
  "submit",
] as const;

export type PathStepKind = (typeof PATH_STEP_KINDS)[number];

export const PATH_EFFECTS = ["navigate", "input", "commit"] as const;

export type PathEffect = (typeof PATH_EFFECTS)[number];

export interface PathStepRequirement {
  readonly permission?: PathPermission;
  readonly screen?: readonly string[];
  readonly focused?: string;
  readonly url?: string;
  readonly locator?: string;
  readonly text?: readonly string[];
  /** Poll the surface for up to this many milliseconds until preconditions hold. */
  readonly wait?: number;
}

export interface PathStep {
  readonly id: string;
  readonly title?: string;
  readonly kind: PathStepKind;
  readonly target?: string;
  readonly locator?: string;
  readonly url?: string;
  readonly text?: string;
  readonly effect?: PathEffect;
  readonly require?: PathStepRequirement;
}

export interface PathDocument {
  readonly schemaVersion: typeof PATH_SCHEMA_VERSION;
  readonly id: string;
  readonly version: string;
  readonly title: string;
  readonly surface: PathSurface;
  readonly legacyPackage?: string;
  /** Origins `goto` / page mutations may run on. Required by the body core for page `goto` / `click` / `fill`. */
  readonly allowedOrigins?: readonly string[];
  readonly steps: readonly PathStep[];
}

export interface PathCatalogEntry {
  readonly id: string;
  readonly version: string;
  readonly href: string;
}

export interface PathCatalog {
  readonly schemaVersion: typeof PATH_SCHEMA_VERSION;
  readonly paths: readonly PathCatalogEntry[];
}

export const PATH_ID_PATTERN = /^[a-z][a-z0-9-]{0,63}$/;
export const PATH_VERSION_PATTERN = /^\d+\.\d+\.\d+$/;
