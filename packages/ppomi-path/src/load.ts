import { readFileSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { PathError } from "./errors.ts";
import type { PathCatalog, PathDocument } from "./schema.ts";
import { validatePathCatalog, validatePathDocument } from "./validate.ts";

export function defaultCatalogRoot(): string {
  return fileURLToPath(new URL("../../../catalogs/paths/", import.meta.url)).replace(/[/\\]+$/, "");
}

export function loadPathCatalog(root: string = defaultCatalogRoot()): PathCatalog {
  return validatePathCatalog(readJson(path.join(root, "index.json"), "path catalog"));
}

export function loadPath(
  id: string,
  options: { readonly version?: string; readonly root?: string } = {},
): PathDocument {
  const root = options.root ?? defaultCatalogRoot();
  const catalog = loadPathCatalog(root);
  const matches = catalog.paths.filter(entry => entry.id === id);
  if (matches.length === 0) {
    throw new PathError("path_not_found", `path not in catalog: ${id}`);
  }
  const entry =
    options.version === undefined
      ? matches[matches.length - 1]
      : matches.find(item => item.version === options.version);
  if (entry === undefined) {
    throw new PathError("path_version", `path ${id} has no version ${options.version}`);
  }
  return validatePathDocument(readJson(resolveInside(root, entry.href), `path ${id}`));
}

function resolveInside(root: string, href: string): string {
  const rootResolved = path.resolve(root);
  const resolved = path.resolve(root, href);
  if (resolved !== rootResolved && !resolved.startsWith(`${rootResolved}${path.sep}`)) {
    throw new PathError("href", `catalog href escapes root: ${href}`);
  }
  return resolved;
}

function readJson(file: string, label: string): unknown {
  try {
    return JSON.parse(readFileSync(file, "utf8")) as unknown;
  } catch (error) {
    if (error instanceof PathError) throw error;
    throw new PathError("read", `failed to read ${label} at ${file}`);
  }
}
