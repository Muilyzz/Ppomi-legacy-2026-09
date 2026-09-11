import { spawnSync } from "node:child_process";
import { cp, mkdir, readdir, rm } from "node:fs/promises";
import { fileURLToPath } from "node:url";
import path from "node:path";
import os from "node:os";

const root = fileURLToPath(new URL("../../", import.meta.url));
const mode = process.argv[2] ?? "debug";
if (!["debug", "release"].includes(mode)) throw new Error("Expected debug or release");
const resources = path.join(root, "shell/src-tauri/resources");
const stage = path.join(resources, "executor");
const env = { ...process.env, CLANG_MODULE_CACHE_PATH: path.join(os.tmpdir(), "ppomi-executor-module-cache"),
  SWIFT_MODULECACHE_PATH: path.join(os.tmpdir(), "ppomi-executor-module-cache") };
function run(command, args, cwd, capture = false) {
  const result = spawnSync(command, args, { cwd, env, encoding: "utf8", stdio: capture ? ["ignore", "pipe", "inherit"] : "inherit" });
  if (result.error || result.status !== 0) throw new Error(`${command} failed; executor was not packaged`);
  return result.stdout?.trim();
}
await mkdir(stage, { recursive: true });
if (process.platform === "darwin") {
  const cwd = path.join(root, "Ppomi");
  run("swift", ["build", "--disable-sandbox", "-c", mode, "--product", "Ppomi"], cwd);
  const bin = run("swift", ["build", "--disable-sandbox", "-c", mode, "--show-bin-path"], cwd, true);
  await cp(path.join(bin, "Ppomi"), path.join(stage, "ppomi-executor"));
  for (const name of await readdir(bin)) if (name.endsWith(".bundle")) {
    const target = path.join(resources, name);
    await rm(target, { recursive: true, force: true });
    await cp(path.join(bin, name), target, { recursive: true });
  }
} else if (process.platform === "win32") {
  const runtime = process.arch === "arm64" ? "win-arm64" : "win-x64";
  run("dotnet", ["publish", path.join(root, "executors/windows/Executor/Ppomi.Executor.Windows.csproj"),
    "-c", mode === "release" ? "Release" : "Debug", "-r", runtime, "--self-contained", "true",
    "-p:PublishSingleFile=true", "-p:IncludeNativeLibrariesForSelfExtract=true", "-o", stage], root);
} else {
  throw new Error("Desktop executors currently support macOS and Windows. Build each package on its target OS.");
}
console.log(`Packaged ${process.platform} executor (${mode}).`);
