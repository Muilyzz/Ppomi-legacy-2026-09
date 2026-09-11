import { spawnSync } from "node:child_process";
import { existsSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const packageRoot = resolve(dirname(fileURLToPath(import.meta.url)), "..", "..");
const repoRoot = resolve(packageRoot, "..", "..");
const liveTest = join(packageRoot, "tests", "live-edge-uia-smoke.test.ts");
const LIVE_COMMAND =
  "PPOMI_BODY_LIVE=1 node --experimental-strip-types packages/ppomi-body-windows/example/src/main.ts";

export type LiveProbeStatus = "ok" | "skip" | "fail";

export interface LiveProbe {
  readonly status: LiveProbeStatus;
  readonly lines: readonly string[];
}

function executorPath(): string {
  return process.env.PPOMI_EXECUTOR
    ?? join(repoRoot, "shell", "src-tauri", "resources", "executor", "ppomi-executor.exe");
}

function edgePath(): string | undefined {
  const candidates = [
    process.env.PPOMI_EDGE,
    process.env["ProgramFiles(x86)"] && join(process.env["ProgramFiles(x86)"], "Microsoft", "Edge", "Application", "msedge.exe"),
    process.env.ProgramFiles && join(process.env.ProgramFiles, "Microsoft", "Edge", "Application", "msedge.exe"),
  ].filter((candidate): candidate is string => typeof candidate === "string");
  return candidates.find(candidate => existsSync(candidate));
}

/** Isolated Edge + `ppomi-executor` 1-step. Off-Windows or without PPOMI_BODY_LIVE=1 this skips. */
export function probeWindowsLive(): LiveProbe {
  const live = process.env.PPOMI_BODY_LIVE === "1";
  if (process.platform !== "win32") {
    return {
      status: "skip",
      lines: [
        `platform  ${process.platform}`,
        "live      SKIP (not Windows)",
        `          ${LIVE_COMMAND}`,
        "          or: npm --prefix packages/ppomi-body-windows run smoke:live",
      ],
    };
  }

  const executor = executorPath();
  const edge = edgePath();
  const lines = [
    `platform  ${process.platform}`,
    `executor  ${existsSync(executor) ? executor : "(missing; set PPOMI_EXECUTOR)"}`,
    `edge      ${edge ?? "(missing; set PPOMI_EDGE)"}`,
    `live      ${live ? "PPOMI_BODY_LIVE=1" : "off (set PPOMI_BODY_LIVE=1 for isolated Edge + ppomi-executor)"}`,
  ];

  if (!live) {
    return { status: "ok", lines: [...lines, "probe     dry-run — no Edge / executor"] };
  }
  if (!existsSync(executor) || edge === undefined) {
    return { status: "skip", lines: [...lines, "probe     SKIP — executor or Edge missing"] };
  }

  const result = spawnSync(process.execPath, ["--experimental-strip-types", "--test", liveTest], {
    encoding: "utf8",
    env: process.env,
    timeout: 130_000,
  });
  const text = `${result.stdout ?? ""}${result.stderr ?? ""}`.trim();
  const outcome = liveReporterOutcome(result.status, text);
  if (outcome === "skip") {
    return { status: "skip", lines: [...lines, "probe     SKIP — live UIA test skipped", compact(text)] };
  }
  if (outcome === "ok") {
    return { status: "ok", lines: [...lines, "probe     Edge UIA read→type→tap via ppomi-executor"] };
  }
  return { status: "fail", lines: [...lines, "probe     FAIL — live UIA did not complete", compact(text)] };
}

/** Node's spec reporter may print `# pass 1` or `ℹ pass 1`. Exit 0 + a pass/skip count is what matters. */
export function liveReporterOutcome(status: number | null, text: string): LiveProbeStatus {
  const passed = /pass\s+[1-9]/.test(text);
  const skipped = /skipped\s+[1-9]/.test(text) || /\bSKIP\b/.test(text);
  if (status === 0 && skipped && !passed) return "skip";
  if (status === 0 && passed) return "ok";
  return "fail";
}

export function writeLiveProbe(probe: LiveProbe): void {
  const label = probe.status === "fail" ? "FAIL" : probe.status === "skip" ? "SKIP" : "PASS";
  process.stdout.write(`  live     ${label}\n`);
  for (const line of probe.lines) {
    process.stdout.write(`           ${line}\n`);
  }
  if (probe.status === "fail") process.exitCode = 1;
}

function compact(text: string): string {
  const line = text.split(/\r?\n/).map(part => part.trim()).filter(part => part.length > 0).at(-1);
  return line === undefined ? "          (no tester output)" : `          ${line.slice(0, 200)}`;
}
