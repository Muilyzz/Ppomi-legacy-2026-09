import { existsSync, readdirSync, statSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";

/** Conventional Windows 공동인증서 store. Not certmgr. Filenames / DNs are never returned. */
export function defaultNpkiRoot(env: NodeJS.ProcessEnv = process.env): string {
  if (typeof env.PPOMI_NPKI_ROOT === "string" && env.PPOMI_NPKI_ROOT.length > 0) {
    return env.PPOMI_NPKI_ROOT;
  }
  const home = env.USERPROFILE ?? homedir();
  return join(home, "AppData", "LocalLow", "NPKI");
}

export type NpkiProbeStatus = "ok" | "skip" | "missing";

export interface NpkiProbe {
  readonly status: NpkiProbeStatus;
  readonly root: string;
  readonly fileCount: number;
  readonly newestMtimeMs: number | null;
  /** Files with mtime >= sinceMs. Omitted when sinceMs is not given. */
  readonly newerThanCount?: number;
}

export interface NpkiProbeOptions {
  readonly root?: string;
  readonly platform?: NodeJS.Platform;
  readonly env?: NodeJS.ProcessEnv;
  /** Compare mtimes to this instant (post-issue). */
  readonly sinceMs?: number;
}

/**
 * Count files under NPKI. No file contents, no relative paths, no DNs.
 * Off-Windows without PPOMI_NPKI_ROOT / an explicit root → skip (manual verify).
 */
export function probeNpki(options: NpkiProbeOptions = {}): NpkiProbe {
  const platform = options.platform ?? process.platform;
  const env = options.env ?? process.env;
  const explicit = options.root ?? env.PPOMI_NPKI_ROOT;
  if (platform !== "win32" && (explicit === undefined || explicit.length === 0)) {
    return {
      status: "skip",
      root: defaultNpkiRoot(env),
      fileCount: 0,
      newestMtimeMs: null,
    };
  }

  const root = options.root ?? defaultNpkiRoot(env);
  if (!existsSync(root)) {
    return { status: "missing", root, fileCount: 0, newestMtimeMs: null };
  }

  let fileCount = 0;
  let newestMtimeMs: number | null = null;
  let newerThanCount = 0;
  const stack = [root];
  while (stack.length > 0) {
    const dir = stack.pop()!;
    let names: string[];
    try {
      names = readdirSync(dir);
    } catch {
      continue;
    }
    for (const name of names) {
      const next = join(dir, name);
      let st: ReturnType<typeof statSync>;
      try {
        st = statSync(next);
      } catch {
        continue;
      }
      if (st.isDirectory()) {
        stack.push(next);
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
  };
}
