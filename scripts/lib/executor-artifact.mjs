/**
 * Selection and verification rules for a downloaded `ppomi-executor.exe` CI artifact.
 * Pure functions over an injected `gh` runner and the filesystem, so the CLI in
 * ../build-windows-executor.mjs and its tests share one implementation.
 *
 * Trust model: only artifacts built by the `windows-executor` workflow from a `push`
 * to `main` or a `workflow_dispatch` are eligible — never a `pull_request` run,
 * whose code may come from a fork. The artifact must ship a SHA256SUMS file and the
 * exe must match it; anything missing or different fails closed.
 */
import { createHash } from "node:crypto";
import { existsSync, readFileSync } from "node:fs";
import { join } from "node:path";

export const REPO = "Muilyzz/Ppomi";
export const WORKFLOW = "windows-executor.yml";
export const WORKFLOW_NAME = "windows-executor";
export const EXE = "ppomi-executor.exe";
export const SUMS = "SHA256SUMS";
export const DEFAULT_BRANCH = "main";
export const ALLOWED_EVENTS = new Set(["push", "workflow_dispatch"]);

export class ArtifactError extends Error {
  constructor(message) {
    super(message);
    this.name = "ArtifactError";
  }
}

/**
 * Pick the run to download from.
 * @param {(args: string[]) => { status: number | null, stdout: string, stderr: string }} gh  runs the GitHub CLI
 * @param {{ runId?: string, branch?: string }} options  an explicit `--run <id>`, or the branch to search (default main)
 * @returns {{ id: number, headSha: string, headBranch: string, event: string }}
 */
export function selectRun(gh, options = {}) {
  const branch = options.branch ?? DEFAULT_BRANCH;
  if (options.runId !== undefined) {
    if (!/^\d+$/.test(options.runId)) throw new ArtifactError(`--run must be a numeric run id (got ${options.runId})`);
    const view = ghJson(gh, ["run", "view", options.runId, "--repo", REPO, "--json", "databaseId,headSha,headBranch,event,status,conclusion,workflowName"]);
    if (view.workflowName !== WORKFLOW_NAME) {
      throw new ArtifactError(`run ${options.runId} belongs to workflow ${view.workflowName ?? "?"}, not ${WORKFLOW_NAME}`);
    }
    if (view.status !== "completed" || view.conclusion !== "success") {
      throw new ArtifactError(`run ${options.runId} is ${view.status}/${view.conclusion ?? "?"}, not a successful run`);
    }
    return eligible({ id: view.databaseId, headSha: view.headSha, headBranch: view.headBranch, event: view.event });
  }
  const runs = ghJson(gh, [
    "run", "list",
    "--repo", REPO,
    "--workflow", WORKFLOW,
    "--branch", branch,
    "--event", "push",
    "--status", "success",
    "--limit", "1",
    "--json", "databaseId,headSha,headBranch,event",
  ]);
  const first = Array.isArray(runs) ? runs[0] : undefined;
  if (first === undefined) throw new ArtifactError(`no successful push run of ${WORKFLOW} on ${branch}; publish locally or pass --run <id>`);
  return eligible({ id: first.databaseId, headSha: first.headSha, headBranch: first.headBranch, event: first.event });
}

/** Refuse anything a fork could have produced. */
export function eligible(run) {
  if (!ALLOWED_EVENTS.has(run.event)) {
    throw new ArtifactError(`run ${run.id} was triggered by ${run.event}; only push / workflow_dispatch artifacts are trusted`);
  }
  if (typeof run.headSha !== "string" || !/^[0-9a-f]{40}$/.test(run.headSha)) {
    throw new ArtifactError(`run ${run.id} has no usable commit SHA`);
  }
  return run;
}

/** `SHA256SUMS` lines are `<hex>  <file>`; returns the hex for `fileName` or null. */
export function parseSha256Sums(text, fileName) {
  for (const raw of text.split(/\r?\n/)) {
    const line = raw.trim();
    if (line.length === 0 || line.startsWith("#")) continue;
    const match = /^([0-9a-fA-F]{64})\s+\*?(.+)$/.exec(line);
    if (match !== null && match[2].trim() === fileName) return match[1].toLowerCase();
  }
  return null;
}

export function sha256File(path) {
  return createHash("sha256").update(readFileSync(path)).digest("hex");
}

/**
 * The downloaded artifact directory must contain the exe and a SHA256SUMS naming it with
 * the exe's actual hash. Returns the verified hash.
 */
export function verifyArtifactDir(dir, exe = EXE) {
  const exePath = join(dir, exe);
  const sumsPath = join(dir, SUMS);
  if (!existsSync(exePath)) throw new ArtifactError(`artifact has no ${exe}`);
  if (!existsSync(sumsPath)) throw new ArtifactError(`artifact has no ${SUMS}; refusing an unverifiable binary`);
  const expected = parseSha256Sums(readFileSync(sumsPath, "utf8"), exe);
  if (expected === null) throw new ArtifactError(`${SUMS} does not list ${exe}`);
  const actual = sha256File(exePath);
  if (actual !== expected) throw new ArtifactError(`${exe} sha256 ${actual} does not match ${SUMS} ${expected}`);
  return actual;
}

function ghJson(gh, args) {
  const result = gh(args);
  if (result.status !== 0) throw new ArtifactError((result.stderr || `gh ${args.slice(0, 2).join(" ")} failed`).trim());
  try {
    return JSON.parse(result.stdout || "null");
  } catch {
    throw new ArtifactError(`gh ${args.slice(0, 2).join(" ")} returned invalid JSON`);
  }
}
