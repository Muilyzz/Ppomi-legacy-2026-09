import { spawn, spawnSync } from "node:child_process";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { publicUrl } from "../../../ppomi-body/src/index.ts";

export const EDGE_IMAGE_NAME = "msedge.exe";
export const CLOSE_EDGE_ENV = "PPOMI_KB_CERT_CLOSE_EDGE";

export interface EdgeChild {
  readonly pid: number | undefined;
  /** Node saw the process exit. A hand-off to an already running Edge exits within milliseconds. */
  exited(): boolean;
}

/** Test seam. The defaults spawn `msedge.exe`, run `tasklist` / `taskkill`, and own the temp profile. */
export interface EdgePorts {
  spawn(exe: string, args: readonly string[]): EdgeChild;
  /** stdout of `tasklist /FI "PID eq <pid>" /FO CSV /NH`, or null when tasklist itself failed. */
  tasklist(pid: number): string | null;
  /** Exit status of `taskkill /PID <pid> /T /F`. Only ever called on our own isolated instance. */
  taskkill(pid: number): number;
  mkdtemp(): string;
  rm(dir: string): void;
  sleep(ms: number): Promise<void>;
}

export interface EdgeOpenOptions {
  readonly edge: string;
  readonly url: string;
  /** PPOMI_KB_CERT_CLOSE_EDGE=1: open in a fresh temp profile and close that instance only. */
  readonly closeEdge: boolean;
  readonly ports?: EdgePorts;
}

export type EdgeOpenStatus = "left-open" | "closed" | "not-closed";

export interface EdgeOpenResult {
  readonly status: EdgeOpenStatus;
  readonly lines: readonly string[];
  /** Arguments given to msedge.exe. */
  readonly args: readonly string[];
}

export interface CloseDecision {
  readonly close: boolean;
  readonly reason: string;
}

export function edgeArgs(url: string, userDataDir: string | undefined): readonly string[] {
  return [
    ...(userDataDir === undefined ? [] : [`--user-data-dir=${userDataDir}`]),
    "--no-first-run",
    "--no-default-browser-check",
    "--new-window",
    url,
  ];
}

/** One `tasklist /FO CSV /NH` row for `pid`, or null when no running task has that PID. */
export function parseTasklistCsv(output: string, pid: number): { readonly imageName: string; readonly pid: number } | null {
  for (const line of output.split(/\r?\n/)) {
    const row = line.trim();
    if (!row.startsWith("\"") || !row.endsWith("\"")) continue;
    const fields = row.slice(1, -1).split("\",\"");
    const [imageName, pidText] = fields;
    if (imageName === undefined || pidText === undefined) continue;
    if (/^\d+$/.test(pidText) && Number(pidText) === pid) return { imageName, pid };
  }
  return null;
}

/**
 * The only case the example may end a process: the Edge it launched itself into a
 * dedicated profile, still running, and `tasklist` names that PID `msedge.exe`.
 * The person's own Edge never satisfies `isolated`.
 */
export function closeDecision(input: {
  readonly isolated: boolean;
  readonly child: EdgeChild;
  readonly tasklistOutput: string | null;
}): CloseDecision {
  if (!input.isolated) return { close: false, reason: "not an isolated profile" };
  if (input.child.pid === undefined) return { close: false, reason: "no pid" };
  if (input.child.exited()) return { close: false, reason: "process already exited" };
  if (input.tasklistOutput === null) return { close: false, reason: "tasklist unavailable" };
  const row = parseTasklistCsv(input.tasklistOutput, input.child.pid);
  if (row === null) return { close: false, reason: "pid is not running" };
  if (row.imageName.toLowerCase() !== EDGE_IMAGE_NAME) {
    return { close: false, reason: `pid is ${row.imageName}, not ${EDGE_IMAGE_NAME}` };
  }
  return { close: true, reason: `isolated ${EDGE_IMAGE_NAME} alive` };
}

/**
 * Open `url` in Edge and stop. Default: the person's profile, one new window, nothing
 * is ever closed. With `closeEdge`: a `mkdtemp` profile, then the instance is closed
 * only when `closeDecision` says so; there is no timer kill.
 */
export async function openInEdge(options: EdgeOpenOptions): Promise<EdgeOpenResult> {
  const ports = options.ports ?? defaultPorts;
  const profileDir = options.closeEdge ? ports.mkdtemp() : undefined;
  const args = edgeArgs(options.url, profileDir);
  const child = ports.spawn(options.edge, args);
  const opened = `opened Edge ${publicUrl(options.url)} (${profileDir === undefined ? "your profile" : "isolated temp profile"})`;

  if (profileDir === undefined) {
    return {
      status: "left-open",
      lines: [opened, `left open for the person — nothing is closed (${CLOSE_EDGE_ENV}=1 opens and closes an isolated profile instead)`],
      args,
    };
  }

  const tasklistOutput = child.pid === undefined ? null : ports.tasklist(child.pid);
  const decision = closeDecision({ isolated: true, child, tasklistOutput });
  if (!decision.close || child.pid === undefined) {
    return { status: "not-closed", lines: [opened, `not closed — ${decision.reason}; close the isolated window yourself`], args };
  }
  const status = ports.taskkill(child.pid);
  if (status !== 0) {
    return { status: "not-closed", lines: [opened, `not closed — taskkill exit ${status}; close the isolated window yourself`], args };
  }
  await removeProfile(ports, profileDir);
  return { status: "closed", lines: [opened, "closed the isolated Edge instance (temp profile removed)"], args };
}

/** Edge releases its profile directory a moment after it exits; a leftover temp dir is not a failure. */
async function removeProfile(ports: EdgePorts, dir: string): Promise<void> {
  for (let attempt = 0; attempt < 10; attempt += 1) {
    try {
      ports.rm(dir);
      return;
    } catch {
      await ports.sleep(500);
    }
  }
}

const defaultPorts: EdgePorts = {
  spawn(exe, args) {
    const child = spawn(exe, args, { stdio: "ignore", detached: true });
    let exited = false;
    child.once("exit", () => {
      exited = true;
    });
    child.unref();
    return { pid: child.pid, exited: () => exited };
  },
  tasklist(pid) {
    const result = spawnSync("tasklist", ["/FI", `PID eq ${pid}`, "/FO", "CSV", "/NH"], {
      encoding: "utf8",
      stdio: ["ignore", "pipe", "ignore"],
    });
    return result.status === 0 && typeof result.stdout === "string" ? result.stdout : null;
  },
  taskkill(pid) {
    return spawnSync("taskkill", ["/PID", String(pid), "/T", "/F"], { stdio: "ignore" }).status ?? 1;
  },
  mkdtemp: () => mkdtempSync(join(tmpdir(), "ppomi-kb-cert-edge-")),
  rm: dir => rmSync(dir, { recursive: true, force: true }),
  sleep: ms => new Promise(done => setTimeout(done, ms)),
};
