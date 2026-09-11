#!/usr/bin/env node
/**
 * Publish or fetch `ppomi-executor.exe` for ppomi-body-windows live smoke.
 *
 *   node scripts/build-windows-executor.mjs              # this machine's RID (win-x64 off Windows)
 *   node scripts/build-windows-executor.mjs --rid win-arm64
 *   node scripts/build-windows-executor.mjs --download   # latest CI artifact (needs gh)
 *
 * Stages the smoke default: shell/src-tauri/resources/executor/ppomi-executor.exe
 * Needs .NET 10 SDK to publish (winget install Microsoft.DotNet.SDK.10).
 */
import { spawnSync } from "node:child_process";
import { copyFileSync, existsSync, mkdirSync, mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const root = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const rids = new Set(["win-x64", "win-arm64"]);
const args = process.argv.slice(2);
const download = args.includes("--download");
const debug = args.includes("--debug");
const ridFlag = args.indexOf("--rid");
const rid = ridFlag >= 0 ? args[ridFlag + 1] : defaultRid();
const stage = join(root, "shell", "src-tauri", "resources", "executor");
const artifact = join(root, "executors", "windows", "artifacts", rid);
const exe = "ppomi-executor.exe";

if (args.includes("--help") || args.includes("-h")) {
  process.stdout.write(`Usage: node scripts/build-windows-executor.mjs [--rid win-x64|win-arm64] [--debug|--download]\n`);
  process.exit(0);
}
if (!rids.has(rid)) {
  process.stderr.write(`unknown --rid ${rid ?? "(missing)"}; use win-x64 or win-arm64\n`);
  process.exit(2);
}

if (download) {
  fetchArtifact(rid);
} else {
  publish(rid, debug ? "Debug" : "Release");
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
  const list = spawnSync("gh", [
    "run", "list",
    "--repo", "Muilyzz/Ppomi",
    "--workflow", "windows-executor.yml",
    "--status", "success",
    "--limit", "1",
    "--json", "databaseId",
  ], { encoding: "utf8" });
  if (list.status !== 0) {
    process.stderr.write(list.stderr || "gh run list failed\n");
    process.exit(list.status ?? 1);
  }
  const runs = JSON.parse(list.stdout || "[]");
  const id = runs[0]?.databaseId;
  if (id === undefined) {
    process.stderr.write(`no successful windows-executor run for ${name}; publish locally instead\n`);
    process.exit(1);
  }
  const work = mkdtempSync(join(tmpdir(), "ppomi-executor-"));
  try {
    run("gh", ["run", "download", String(id), "--repo", "Muilyzz/Ppomi", "--name", name, "--dir", work]);
    const source = join(work, exe);
    if (!existsSync(source)) {
      process.stderr.write(`artifact ${name} from run ${id} has no ${exe}\n`);
      process.exit(1);
    }
    mkdirSync(stage, { recursive: true });
    copyFileSync(source, join(stage, exe));
    process.stdout.write(`downloaded ${join(stage, exe)} (${name} run ${id})\n`);
  } finally {
    rmSync(work, { recursive: true, force: true });
  }
}
