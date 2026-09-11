import { existsSync, mkdtempSync, writeFileSync } from "node:fs";
import { spawn } from "node:child_process";
import { tmpdir } from "node:os";
import path from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..", "..", "..", "..");

function defaultExecutor(): string {
  return process.env.PPOMI_EXECUTOR
    ?? path.join(repoRoot, "shell", "src-tauri", "resources", "executor", "ppomi-executor.exe");
}

function findEdge(): string | null {
  const candidates = [
    process.env.PPOMI_EDGE,
    process.env["ProgramFiles(x86)"] && path.join(process.env["ProgramFiles(x86)"], "Microsoft", "Edge", "Application", "msedge.exe"),
    process.env.ProgramFiles && path.join(process.env.ProgramFiles, "Microsoft", "Edge", "Application", "msedge.exe"),
  ];
  for (const candidate of candidates) {
    if (typeof candidate === "string" && existsSync(candidate)) return candidate;
  }
  return null;
}

function writeSmokePage(): string {
  const dir = mkdtempSync(path.join(tmpdir(), "ppomi-windows-example-"));
  const page = path.join(dir, "smoke.html");
  writeFileSync(page, `<!doctype html><html lang="ko"><head><meta charset="utf-8"><title>Ppomi body example</title></head>
<body><h1>Ppomi Windows body example</h1><p>Isolated profile. No login.</p></body></html>`);
  return page;
}

async function launchEdge(edgePath: string, page: string): Promise<void> {
  const profile = mkdtempSync(path.join(tmpdir(), "ppomi-edge-profile-"));
  const child = spawn(edgePath, [
    `--user-data-dir=${profile}`,
    "--no-first-run",
    "--no-default-browser-check",
    "--force-renderer-accessibility",
    "--new-window",
    pathToFileURL(page).href,
  ], { stdio: "ignore", detached: true });
  child.unref();
}

async function probeWin32(): Promise<{ status: "ok" | "skip" | "fail"; lines: string[] }> {
  const executor = defaultExecutor();
  const edge = findEdge();
  const live = process.env.PPOMI_BODY_LIVE === "1";
  const lines = [
    `platform  ${process.platform}`,
    `edge      ${edge ?? "(not found; set PPOMI_EDGE)"}`,
    `executor  ${existsSync(executor) ? executor : `(missing) ${executor}`}`,
    `live      ${live ? "PPOMI_BODY_LIVE=1" : "off (set PPOMI_BODY_LIVE=1 to launch isolated Edge)"}`,
    "note      Full UIA read/type/tap is PR #15 driver-windows `npm run smoke:live`.",
  ];

  if (!live) {
    return { status: "ok", lines: [...lines, "probe     dry-run — paths listed, no UIA"] };
  }
  if (edge === null) {
    return { status: "skip", lines: [...lines, "probe     SKIP — Edge not found"] };
  }

  try {
    await launchEdge(edge, writeSmokePage());
    return { status: "ok", lines: [...lines, "probe     launched isolated Edge on a local page"] };
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    return { status: "fail", lines: [...lines, `probe     FAIL  ${message}`] };
  }
}

async function main(): Promise<void> {
  if (process.platform !== "win32") {
    process.stdout.write("adapter-windows example: SKIP\n");
    process.stdout.write(`  reason   not Windows (${process.platform})\n`);
    process.stdout.write("  future   ppomi-body-windows. Live UIA: packages/driver-windows (PR #15).\n");
    return;
  }

  const probe = await probeWin32();
  const label = probe.status === "fail" ? "FAIL" : probe.status === "skip" ? "SKIP" : "PASS";
  process.stdout.write(`adapter-windows example: ${label}\n`);
  for (const line of probe.lines) {
    process.stdout.write(`  ${line}\n`);
  }
  if (probe.status === "fail") process.exitCode = 1;
}

main().catch(error => {
  const message = error instanceof Error ? error.message : String(error);
  process.stderr.write(`adapter-windows example: FAIL\n  ${message}\n`);
  process.exitCode = 1;
});
