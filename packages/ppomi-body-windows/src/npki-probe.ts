import { existsSync, lstatSync, readdirSync } from "node:fs";
import { homedir } from "node:os";
import { isAbsolute, join, relative, resolve, sep } from "node:path";

/**
 * Directory levels the walk descends below the root. The conventional store is
 * `NPKI\<CA>\USER\<DN folder>\signCert.der`, so the files sit inside a depth-3 folder.
 */
export const NPKI_MAX_DEPTH = 3;
/** Directory entries visited before the walk stops and reports `truncated`. */
export const NPKI_MAX_ENTRIES = 2048;

export type NpkiRootSource = "default" | "override";

export type NpkiProbeStatus = "ok" | "skip" | "missing" | "refused";

export interface NpkiProbe {
  readonly status: NpkiProbeStatus;
  /** Which root was probed. The path itself never leaves this module. */
  readonly root: NpkiRootSource;
  readonly fileCount: number;
  readonly newestMtimeMs: number | null;
  /** Files with mtime >= sinceMs. Omitted when sinceMs is not given. */
  readonly newerThanCount?: number;
  /** The walk stopped at `maxEntries` before finishing. */
  readonly truncated: boolean;
}

export interface NpkiProbeOptions {
  /** Override root; same rule as PPOMI_NPKI_ROOT (absolute, strictly under the profile). */
  readonly root?: string;
  readonly platform?: NodeJS.Platform;
  readonly env?: NodeJS.ProcessEnv;
  /** Compare mtimes to this instant (post-issue). */
  readonly sinceMs?: number;
  readonly maxDepth?: number;
  readonly maxEntries?: number;
}

/** Conventional Windows 공동인증서 store. Not certmgr. Filenames / DNs are never returned. */
export function defaultNpkiRoot(env: NodeJS.ProcessEnv = process.env): string {
  return join(profileHome(env), "AppData", "LocalLow", "NPKI");
}

type RootResolution =
  | { readonly kind: "default" | "override"; readonly path: string }
  | { readonly kind: "refused" };

/**
 * PPOMI_NPKI_ROOT (or `options.root`) may only point at an absolute directory strictly
 * under %USERPROFILE%; the profile itself, anything outside it, a relative path, or a
 * root that is a link is refused. Without an override the conventional store is used.
 */
export function resolveNpkiRoot(
  explicit: string | undefined,
  env: NodeJS.ProcessEnv = process.env,
): RootResolution {
  if (explicit === undefined || explicit.length === 0) {
    return { kind: "default", path: defaultNpkiRoot(env) };
  }
  if (!isAbsolute(explicit)) return { kind: "refused" };
  const home = resolve(profileHome(env));
  const candidate = resolve(explicit);
  const rel = relative(home, candidate);
  if (rel === "" || rel === ".." || rel.startsWith(`..${sep}`) || isAbsolute(rel)) {
    return { kind: "refused" };
  }
  return { kind: "override", path: candidate };
}

/**
 * Count files under NPKI. No file contents, no names, no paths leave this function.
 * Links are never followed (lstat), the walk is bounded by depth and entry count.
 * Off-Windows without an override → skip (manual verify).
 */
export function probeNpki(options: NpkiProbeOptions = {}): NpkiProbe {
  const platform = options.platform ?? process.platform;
  const env = options.env ?? process.env;
  const explicit = options.root ?? env.PPOMI_NPKI_ROOT;
  const resolution = resolveNpkiRoot(explicit, env);
  if (resolution.kind === "refused") return empty("refused", "override");

  const root = resolution.kind;
  if (platform !== "win32" && root === "default") return empty("skip", root);
  if (!existsSync(resolution.path)) return empty("missing", root);
  const rootStat = lstatSync(resolution.path);
  if (rootStat.isSymbolicLink()) return empty("refused", root);
  if (!rootStat.isDirectory()) return empty("missing", root);

  const maxDepth = options.maxDepth ?? NPKI_MAX_DEPTH;
  const maxEntries = options.maxEntries ?? NPKI_MAX_ENTRIES;
  let fileCount = 0;
  let newestMtimeMs: number | null = null;
  let newerThanCount = 0;
  let visited = 0;
  let truncated = false;
  const stack: { readonly dir: string; readonly depth: number }[] = [{ dir: resolution.path, depth: 0 }];
  while (stack.length > 0 && !truncated) {
    const { dir, depth } = stack.pop()!;
    let names: string[];
    try {
      names = readdirSync(dir);
    } catch {
      continue;
    }
    for (const name of names) {
      visited += 1;
      if (visited > maxEntries) {
        truncated = true;
        break;
      }
      const next = join(dir, name);
      let st: ReturnType<typeof lstatSync>;
      try {
        st = lstatSync(next);
      } catch {
        continue;
      }
      if (st.isSymbolicLink()) continue;
      if (st.isDirectory()) {
        if (depth < maxDepth) stack.push({ dir: next, depth: depth + 1 });
        continue;
      }
      if (!st.isFile()) continue;
      fileCount += 1;
      if (newestMtimeMs === null || st.mtimeMs > newestMtimeMs) newestMtimeMs = st.mtimeMs;
      if (options.sinceMs !== undefined && st.mtimeMs >= options.sinceMs) newerThanCount += 1;
    }
  }

  return {
    status: "ok",
    root,
    fileCount,
    newestMtimeMs,
    ...(options.sinceMs === undefined ? {} : { newerThanCount }),
    truncated,
  };
}

function profileHome(env: NodeJS.ProcessEnv): string {
  const profile = env.USERPROFILE;
  return typeof profile === "string" && profile.length > 0 ? profile : homedir();
}

function empty(status: Exclude<NpkiProbeStatus, "ok">, root: NpkiRootSource): NpkiProbe {
  return { status, root, fileCount: 0, newestMtimeMs: null, truncated: false };
}
