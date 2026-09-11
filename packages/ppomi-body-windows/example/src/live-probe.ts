import { spawn, spawnSync } from "node:child_process";
import { existsSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import {
  FixedPermissionGate,
  OsSurface,
  Runtime,
  type Playbook,
  type RunResult,
} from "../../../ppomi-body/src/index.ts";
import {
  LiveWindowsExecutorTools,
  WindowsDriver,
  type WindowsRunningApp,
} from "../../src/index.ts";

const packageRoot = resolve(dirname(fileURLToPath(import.meta.url)), "..", "..");
const repoRoot = resolve(packageRoot, "..", "..");
const LIVE_COMMAND =
  "PPOMI_BODY_LIVE=1 node --experimental-strip-types packages/ppomi-body-windows/example/src/main.ts";
const PROBE_TEXT = "ppomi live probe";

export type LiveProbeStatus = "ok" | "skip" | "fail";

export interface LiveProbe {
  readonly status: LiveProbeStatus;
  readonly lines: readonly string[];
}

/** Texts the probe expects to observe on the page, by exact accessible name. */
export interface LiveProbePage {
  readonly inputLabel: string;
  readonly buttonLabel: string;
  readonly markBefore: string;
  readonly markAfter: string;
}

/** The executor tools the probe may bind; `listApps` / `allowApps` are session setup, everything else runs through `Runtime`. */
export interface LiveProbeTools {
  listApps(query?: string): { readonly apps: readonly WindowsRunningApp[] };
  allowApps(packageNames: readonly string[]): { readonly updated: boolean };
  app_open(args: { target: string }): { readonly packageName: string; readonly activated: boolean };
  screen_read: LiveWindowsExecutorTools["screen_read"];
  ui_tap: LiveWindowsExecutorTools["ui_tap"];
  ui_type: LiveWindowsExecutorTools["ui_type"];
}

/** A live session: tools bound to an executor, the app label to drive, and how to tear everything down. */
export interface LiveSession {
  readonly tools: LiveProbeTools;
  readonly appLabel: string;
  close(): Promise<void>;
}

export interface LiveProbeOptions {
  readonly platform?: NodeJS.Platform;
  /** Defaults to `PPOMI_BODY_LIVE === "1"`. */
  readonly live?: boolean;
  readonly page?: LivePage;
  /** Test seam: supplies the session instead of launching Edge and `ppomi-executor`. */
  readonly session?: () => Promise<LiveSession>;
  readonly waitMs?: number;
  readonly pollIntervalMs?: number;
}

export type LivePage = LiveProbePage;

/** The offline page the default session opens: every text below is an exact UIA name the playbook targets. */
export const EDGE_PAGE: LiveProbePage = {
  inputLabel: "입력 상자",
  buttonLabel: "여기를 탭",
  markBefore: "아직 탭 안 됨",
  markAfter: "탭됨 OK",
};

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

/** Three declared steps: type (`effect: "input"`), tap (`effect: "navigate"`), read back — all gated and recorded by `Runtime`. */
export function liveProbePlaybook(page: LiveProbePage, waitMs: number): Playbook {
  return {
    id: "windows-live-probe",
    steps: [
      {
        id: "type-box",
        kind: "type",
        target: page.inputLabel,
        text: PROBE_TEXT,
        effect: "input",
        require: { screen: [page.buttonLabel, page.markBefore], wait: waitMs },
      },
      { id: "tap-button", kind: "click", target: page.buttonLabel, effect: "navigate" },
      { id: "confirm-tap", kind: "read", require: { screen: [page.markAfter], wait: waitMs } },
    ],
  };
}

/**
 * Isolated Edge + `ppomi-executor`, driven only through `Runtime` + `OsSurface(WindowsDriver)`.
 * Off-Windows or without PPOMI_BODY_LIVE=1 this skips / dry-runs exactly as before.
 */
export async function probeWindowsLive(options: LiveProbeOptions = {}): Promise<LiveProbe> {
  const platform = options.platform ?? process.platform;
  const live = options.live ?? process.env.PPOMI_BODY_LIVE === "1";
  if (platform !== "win32") {
    return {
      status: "skip",
      lines: [
        `platform  ${platform}`,
        "live      SKIP (not Windows)",
        `          ${LIVE_COMMAND}`,
        "          or: npm --prefix packages/ppomi-body-windows run smoke:live",
      ],
    };
  }

  const executor = executorPath();
  const edge = edgePath();
  const lines = [
    `platform  ${platform}`,
    `executor  ${existsSync(executor) ? executor : "(missing; set PPOMI_EXECUTOR)"}`,
    `edge      ${edge ?? "(missing; set PPOMI_EDGE)"}`,
    `live      ${live ? "PPOMI_BODY_LIVE=1" : "off (set PPOMI_BODY_LIVE=1 for isolated Edge + ppomi-executor)"}`,
  ];

  if (!live) {
    return { status: "ok", lines: [...lines, "probe     dry-run — no Edge / executor"] };
  }
  if (options.session === undefined && (!existsSync(executor) || edge === undefined)) {
    return { status: "skip", lines: [...lines, "probe     SKIP — executor or Edge missing"] };
  }

  const page = options.page ?? EDGE_PAGE;
  const waitMs = options.waitMs ?? 15_000;
  const session = await (options.session ?? (() => edgeSession(executor, edge!, page)))();
  try {
    const app = session.tools.listApps("").apps.find(candidate => candidate.label === session.appLabel);
    if (app === undefined) {
      return { status: "skip", lines: [...lines, `probe     SKIP — ${session.appLabel} not in app_list`] };
    }
    // Session setup, not page actions: grant the isolated app and bring its window to the front.
    session.tools.allowApps([app.packageName]);
    session.tools.app_open({ target: app.packageName });

    const runtime = new Runtime(
      new OsSurface(new WindowsDriver(session.tools)),
      new FixedPermissionGate(["ui.read", "ui.control"]),
      { pollIntervalMs: options.pollIntervalMs ?? 500 },
    );
    const result = await runtime.run(liveProbePlaybook(page, waitMs));
    return {
      status: result.status === "completed" ? "ok" : "fail",
      lines: [...lines, ...describeRun(result)],
    };
  } finally {
    await session.close();
  }
}

/** The structured record only: run status, then one line per declared step. Never coordinates or typed text. */
export function describeRun(result: RunResult): string[] {
  const head = result.status === "invalid"
    ? `runtime   invalid (${result.invalid?.code ?? "?"}: ${result.invalid?.detail ?? ""})`
    : `runtime   ${result.status}${result.stopReason === null ? "" : ` (${result.stopReason})`}`;
  const rows = result.stepResults.map(step =>
    `step      ${step.stepId.padEnd(12)} ${step.status.padEnd(11)} ${step.attempt.padEnd(13)} ${(step.code ?? "-").padEnd(20)} ${step.driver}`,
  );
  return [head, ...rows];
}

const sleep = (ms: number): Promise<void> => new Promise(done => setTimeout(done, ms));

/** Own Edge profile on an offline local page; renderer accessibility forced so UIA sees the page, not only the chrome. */
async function edgeSession(executor: string, edge: string, page: LiveProbePage): Promise<LiveSession> {
  const workDir = mkdtempSync(join(tmpdir(), "ppomi-live-probe-"));
  const pagePath = join(workDir, "probe.html");
  writeFileSync(pagePath, pageHtml(page), "utf8");
  const browser = spawn(edge, [
    `--user-data-dir=${join(workDir, "edge-profile")}`,
    "--no-first-run",
    "--no-default-browser-check",
    "--force-renderer-accessibility",
    "--new-window",
    pathToFileURL(pagePath).href,
  ], { stdio: "ignore" });
  await sleep(9_000);
  const tools = LiveWindowsExecutorTools.start({ executorPath: executor });
  return {
    tools,
    appLabel: "msedge",
    async close() {
      tools.close();
      if (browser.pid !== undefined) spawnSync("taskkill", ["/PID", String(browser.pid), "/T", "/F"], { stdio: "ignore" });
      for (let attempt = 0; attempt < 10; attempt += 1) {
        try {
          rmSync(workDir, { recursive: true, force: true });
          return;
        } catch {
          await sleep(500);
        }
      }
    },
  };
}

function pageHtml(page: LiveProbePage): string {
  return `<!doctype html><html lang="ko"><head><meta charset="utf-8"><title>Ppomi live probe</title></head>
<body style="font-family:Segoe UI,sans-serif;padding:48px;font-size:22px">
<h1>Ppomi live probe</h1>
<p><input id="box" type="text" aria-label="${escapeHtml(page.inputLabel)}" style="width:520px;font-size:24px;padding:8px"></p>
<p><button id="btn" type="button" style="font-size:22px;padding:10px 20px"
  onclick="document.getElementById('mark').textContent=${JSON.stringify(page.markAfter)}">${escapeHtml(page.buttonLabel)}</button></p>
<p id="mark" style="font-size:24px">${escapeHtml(page.markBefore)}</p>
</body></html>`;
}

function escapeHtml(text: string): string {
  return text.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;");
}

export function writeLiveProbe(probe: LiveProbe): void {
  const label = probe.status === "fail" ? "FAIL" : probe.status === "skip" ? "SKIP" : "PASS";
  process.stdout.write(`  live     ${label}\n`);
  for (const line of probe.lines) {
    process.stdout.write(`           ${line}\n`);
  }
  if (probe.status === "fail") process.exitCode = 1;
}
