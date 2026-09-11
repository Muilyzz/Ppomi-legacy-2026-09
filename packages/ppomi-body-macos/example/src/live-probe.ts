import { existsSync } from "node:fs";
import {
  FixedPermissionGate,
  OsSurface,
  Runtime,
  type Playbook,
} from "../../../ppomi-body/src/index.ts";
import {
  LiveMacosNativeTools,
  MacosAdapterError,
  MacosDriver,
  liveAxRequested,
  macosBrowserApp,
  pickLiveAxClickTarget,
} from "../../src/index.ts";

const BROWSERS = [
  { id: "safari", app: "/Applications/Safari.app" },
  { id: "chrome", app: "/Applications/Google Chrome.app" },
] as const;

export type LiveProbeStatus = "ok" | "skip" | "fail";

export interface LiveProbe {
  readonly status: LiveProbeStatus;
  readonly lines: readonly string[];
}

function detectBrowsers(): string[] {
  return BROWSERS.filter(browser => existsSync(browser.app)).map(browser => browser.id);
}

function skipLines(lines: readonly string[], detail: string, extra?: string): LiveProbe {
  const out = [...lines, `ax        SKIP — ${detail}`];
  if (extra !== undefined && extra.length > 0) out.push(`          ${extra}`);
  return { status: "skip", lines: out };
}

function errorCode(error: unknown): string {
  if (error instanceof MacosAdapterError) return error.code;
  return error instanceof Error ? error.message : String(error);
}

/** Live AX 1-step through MacosDriver. Off-macOS / no grant / no env → skip (exit 0). */
export async function probeMacLive(): Promise<LiveProbe> {
  const live = liveAxRequested();
  const command = "PPOMI_BODY_LIVE=1 node --experimental-strip-types packages/ppomi-body-macos/example/src/main.ts";
  if (process.platform !== "darwin") {
    return {
      status: "skip",
      lines: [`platform  ${process.platform}`, "live      SKIP (not macOS)", `          ${command}`],
    };
  }

  const browsers = detectBrowsers();
  const lines = [
    `platform  ${process.platform}`,
    `browsers  ${browsers.length > 0 ? browsers.join(",") : "(none in /Applications)"}`,
    `live      ${live ? "PPOMI_BODY_LIVE=1 / PPOMI_BODY_AX=1" : "off (set PPOMI_BODY_LIVE=1 or PPOMI_BODY_AX=1)"}`,
  ];

  if (!live) {
    return { status: "ok", lines: [...lines, "ax        dry-run — fixture only, no System Events / AX"] };
  }

  const preferred = process.env.PPOMI_MAC_BROWSER === "chrome" ? "chrome" : "safari";
  const chosen = browsers.includes(preferred) ? preferred : browsers[0];
  if (chosen === undefined) return skipLines(lines, "no Safari/Chrome");

  const app = macosBrowserApp(chosen);
  if (app === null) return skipLines(lines, "no Safari/Chrome");

  const tools = new LiveMacosNativeTools({ app });
  if (!tools.trusted()) {
    return skipLines(
      lines,
      "Accessibility denied",
      "Grant 손쉬운 사용 to Terminal / iTerm / Cursor, then rerun.",
    );
  }

  try {
    tools.browser_open({ app, url: "https://example.com/" });
  } catch (error) {
    return skipLines(lines, `${app} Automation denied or failed`, errorCode(error));
  }

  let preview;
  try {
    preview = tools.screen_read();
  } catch (error) {
    const code = errorCode(error);
    if (code === "accessibility" || code === "app_not_found") {
      return skipLines(lines, `${app} AX read skipped`, code);
    }
    return { status: "fail", lines: [...lines, `ax        FAIL — screen_read ${code}`] };
  }

  const node = pickLiveAxClickTarget(preview.nodes);
  if (node === undefined) {
    return skipLines(
      lines,
      `${app} front window is not example.com or has no "More information" link — nothing else is clicked`,
      `nodes=${preview.nodes.length}`,
    );
  }

  const oneStep: Playbook = {
    id: "macos-live-ax-1-step",
    steps: [{ id: "ax-click", kind: "click", target: node.text, effect: "navigate" }],
  };

  try {
    const result = await new Runtime(
      new OsSurface(new MacosDriver(tools)),
      new FixedPermissionGate(["ui.read", "ui.control"]),
    ).run(oneStep);
    if (result.status !== "completed" || result.stepResults[0]?.status !== "ok") {
      return {
        status: "fail",
        lines: [
          ...lines,
          `ax        FAIL — Runtime ${result.status} ${result.stepResults[0]?.code ?? "?"}`,
        ],
      };
    }
    return {
      status: "ok",
      lines: [
        ...lines,
        `ax        ${app} click "${node.text}" via MacosDriver + LiveMacosNativeTools (System Events / AX)`,
        `          driver=${result.stepResults[0]?.driver ?? "os-macos"} nodes=${preview.nodes.length}`,
      ],
    };
  } catch (error) {
    const code = errorCode(error);
    if (code === "accessibility") return skipLines(lines, `${app} AX tap skipped`, code);
    return { status: "fail", lines: [...lines, `ax        FAIL — ${code}`] };
  }
}

export async function writeLiveProbe(probe: LiveProbe | Promise<LiveProbe>): Promise<void> {
  const resolved = await probe;
  const label = resolved.status === "fail" ? "FAIL" : resolved.status === "skip" ? "SKIP" : "PASS";
  process.stdout.write(`  live     ${label}\n`);
  for (const line of resolved.lines) {
    process.stdout.write(`           ${line}\n`);
  }
  if (resolved.status === "fail") process.exitCode = 1;
}
