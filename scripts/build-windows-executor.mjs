#!/usr/bin/env node
/**
 * Publish or fetch `ppomi-executor.exe` for ppomi-body-windows live smoke.
 *
 *   node scripts/build-windows-executor.mjs              # this machine's RID (win-x64 off Windows)
 *   node scripts/build-windows-executor.mjs --rid win-arm64
 *   node scripts/build-windows-executor.mjs --download   # latest `push` run on main (needs gh)
 *   node scripts/build-windows-executor.mjs --download --run 123456789
 *
 * `--download` only accepts artifacts the workflow built from a push to main (or a
 * workflow_dispatch named with --run), never from a pull_request, and verifies the
 * exe against the SHA256SUMS published next to it before staging anything.
 *
 * Stages the smoke default: shell/src-tauri/resources/executor/ppomi-executor.exe
 * Needs .NET 10 SDK to publish (winget install Microsoft.DotNet.SDK.10).
 */
import { spawnSync } from "node:child_process";
import { copyFileSync, mkdirSync, mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { ArtifactError, DEFAULT_BRANCH, EXE, REPO, selectRun, verifyArtifactDir } from "./lib/executor-artifact.mjs";

const root = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const rids = new Set(["win-x64", "win-arm64"]);
const args = process.argv.slice(2);
const download = args.includes("--download");
const debug = args.includes("--debug");
const rid = flagValue("--rid") ?? defaultRid();
const runId = flagValue("--run");
const branch = flagValue("--branch") ?? DEFAULT_BRANCH;
const stage = join(root, "shell", "src-tauri", "resources", "executor");
const artifact = join(root, "executors", "windows", "artifacts", rid);
const exe = EXE;

if (args.includes("--help") || args.includes("-h")) {
  process.stdout.write(
    `Usage: node scripts/build-windows-executor.mjs [--rid win-x64|win-arm64] [--debug]\n` +
    `       node scripts/build-windows-executor.mjs --download [--rid ...] [--run <id> | --branch <name>]\n`,
  );
  process.exit(0);
}
if (!rids.has(rid)) {
  process.stderr.write(`unknown --rid ${rid ?? "(missing)"}; use win-x64 or win-arm64\n`);
  process.exit(2);
}
if ((args.includes("--run") && runId === undefined) || (args.includes("--branch") && flagValue("--branch") === undefined)) {
  process.stderr.write("--run and --branch need a value\n");
  process.exit(2);
}

if (download) {
  fetchArtifact(rid);
} else {
  publish(rid, debug ? "Debug" : "Release");
}

function flagValue(flag) {
  const at = args.indexOf(flag);
  if (at < 0) return undefined;
  const value = args[at + 1];
  return value === undefined || value.startsWith("--") ? undefined : value;
}

function defaultRid() {
  if (process.platform === "win32" && process.arch === "arm64") return "win-arm64";
  return "win-x64";
}

function run(command, argv, cwd = root) {
  const result = spawnSync(command, argv, { cwd, encoding: "utf8", stdio: "inherit", shell: process.platform === "win32" });
  if (result.error) throw result.error;
  if (result.status !== 0) process.exit(result.status ?? 1);
}

function gh(argv) {
  const result = spawnSync("gh", argv, { cwd: root, encoding: "utf8", shell: process.platform === "win32" });
  if (result.error) {
    if (result.error.code === "ENOENT") throw new ArtifactError("gh not found. Install the GitHub CLI: https://cli.github.com");
    throw result.error;
  }
  return { status: result.status, stdout: result.stdout ?? "", stderr: result.stderr ?? "" };
}

function publish(runtime, configuration) {
  if (spawnSync("dotnet", ["--version"], { encoding: "utf8" }).status !== 0) {
    process.stderr.write("dotnet not found. Install .NET 10 SDK: winget install Microsoft.DotNet.SDK.10\n");
    process.exit(1);
  }
  const project = join(root, "executors", "windows", "Executor", "Ppomi.Executor.Windows.csproj");
  mkdirSync(artifact, { recursive: true });
  mkdirSync(stage, { recursive: true });
  run("dotnet", [
    "publish", project,
    "-c", configuration,
    "-r", runtime,
    "--self-contained", "true",
    "-p:PublishSingleFile=true",
    "-p:IncludeNativeLibrariesForSelfExtract=true",
    "-o", artifact,
  ]);
  copyFileSync(join(artifact, exe), join(stage, exe));
  process.stdout.write(`staged ${join(stage, exe)} (${runtime} ${configuration})\n`);
}

function fetchArtifact(runtime) {
  const name = `ppomi-executor-${runtime}`;
  const work = mkdtempSync(join(tmpdir(), "ppomi-executor-"));
  let failure;
  try {
    const selected = selectRun(gh, { runId, branch });
    const downloaded = spawnSync(
      "gh",
      ["run", "download", String(selected.id), "--repo", REPO, "--name", name, "--dir", work],
      { cwd: root, encoding: "utf8", stdio: "inherit", shell: process.platform === "win32" },
    );
    if (downloaded.error) throw downloaded.error;
    if (downloaded.status !== 0) throw new ArtifactError(`gh run download ${selected.id} --name ${name} failed`);
    const hash = verifyArtifactDir(work, exe);
    process.stdout.write(`run ${selected.id} commit ${selected.headSha} (${selected.event} on ${selected.headBranch}) sha256 ${hash}\n`);
    mkdirSync(stage, { recursive: true });
    copyFileSync(join(work, exe), join(stage, exe));
    process.stdout.write(`staged ${join(stage, exe)} (${name})\n`);
  } catch (error) {
    if (!(error instanceof ArtifactError)) throw error;
    failure = error.message;
  } finally {
    rmSync(work, { recursive: true, force: true });
  }
  if (failure !== undefined) {
    process.stderr.write(`${failure}\n`);
    process.exit(1);
  }
}
