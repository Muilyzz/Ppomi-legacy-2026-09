import { existsSync } from "node:fs";
import {
  FixedPermissionGate,
  OsSurface,
  Runtime,
  type Playbook,
} from "../../../ppomi-body/src/index.ts";
import {
  IphoneMirroringAdapterError,
  IphoneMirroringDriver,
  LiveIphoneMirroringTools,
  liveIphoneRequested,
} from "../../src/index.ts";

const LIVE_COMMAND =
  "PPOMI_BODY_LIVE=1 node --experimental-strip-types packages/ppomi-body-iphone-mirroring/example/src/main.ts";

const MIRRORING_APPS = [
  "/System/Applications/iPhone Mirroring.app",
  "/Applications/iPhone Mirroring.app",
] as const;

export type LiveProbeStatus = "ok" | "skip" | "fail";

export interface LiveProbe {
  readonly status: LiveProbeStatus;
  readonly lines: readonly string[];
}

function mirroringInstalled(): boolean {
  return MIRRORING_APPS.some(app => existsSync(app));
}

function skipLines(lines: readonly string[], detail: string, extra?: string): LiveProbe {
  const out = [...lines, `probe     SKIP — ${detail}`];
  if (extra !== undefined && extra.length > 0) out.push(`          ${extra}`);
  return { status: "skip", lines: out };
}

function errorCode(error: unknown): string {
  if (error instanceof IphoneMirroringAdapterError) return error.code;
  return error instanceof Error ? error.message : String(error);
}

/**
 * Live read through IphoneMirroringDriver + LiveIphoneMirroringTools.
 * Off-macOS / no env / no window → skip (exit 0). Does not tap Home/Switcher
 * and does not open KB스타기업뱅킹 — that path starts with a human login.
 */
export async function probeIphoneMirroringLive(): Promise<LiveProbe> {
  const live = liveIphoneRequested();
  if (process.platform !== "darwin") {
    return {
      status: "skip",
      lines: [
        `platform  ${process.platform}`,
        "live      SKIP (not macOS)",
        `          ${LIVE_COMMAND}`,
      ],
    };
  }

  const installed = mirroringInstalled();
  const lines = [
    `platform  ${process.platform}`,
    `mirroring ${installed ? "iPhone Mirroring.app" : "(not installed)"}`,
    `live      ${live ? "PPOMI_BODY_LIVE=1" : "off (set PPOMI_BODY_LIVE=1 when mirroring is connected)"}`,
  ];

  if (!live) {
    return { status: "ok", lines: [...lines, "probe     dry-run — fixture only, no AX / phone_*"] };
  }
  if (!installed) return skipLines(lines, "iPhone Mirroring.app missing");

  const tools = new LiveIphoneMirroringTools();
  if (!tools.trusted()) {
    return skipLines(
      lines,
      "Accessibility denied",
      "Grant 손쉬운 사용 (and 화면 기록 for OCR) to Terminal / iTerm / Cursor, then rerun.",
    );
  }

  let preview;
  try {
    tools.phone_open({});
    preview = tools.phone_screen();
  } catch (error) {
    const code = errorCode(error);
    if (code === "accessibility" || code === "app_not_found" || code === "no_phone_cli") {
      return skipLines(
        lines,
        "iPhone Mirroring not connected or Automation denied",
        `${code}. Unlock the Mac, leave the iPhone locked beside it, open iPhone Mirroring until the Home/Switcher chrome is visible.`,
      );
    }
    return { status: "fail", lines: [...lines, `probe     FAIL — phone_screen ${code}`] };
  }

  if (preview.rows.length === 0 && preview.title.trim().length === 0) {
    return skipLines(lines, "mirroring window has no AX/OCR rows", "nodes=0");
  }
  const read = tools.lastRead();
  if (read === null || !read.phoneUi) {
    return skipLines(
      lines,
      "mirroring window read, but only Mac chrome (Home / App Switcher), not the phone UI",
      `source=${read?.source ?? "?"} rows=${preview.rows.length}. Build phone (swiftc -O phone.swift -o phone) and grant 화면 기록 so OCR reads the phone screen.`,
    );
  }

  const oneStep: Playbook = {
    id: "iphone-mirroring-live-read",
    steps: [{ id: "live-read", kind: "read" }],
  };

  try {
    const result = await new Runtime(
      new OsSurface(new IphoneMirroringDriver(tools)),
      new FixedPermissionGate(["ui.read"]),
    ).run(oneStep);
    if (result.status !== "completed" || result.stepResults[0]?.status !== "ok") {
      return {
        status: "fail",
        lines: [
          ...lines,
          `probe     FAIL — Runtime ${result.status} ${result.stepResults[0]?.code ?? "?"}`,
        ],
      };
    }
    return {
      status: "ok",
      lines: [
        ...lines,
        `probe     read "${preview.title}" via IphoneMirroringDriver + LiveIphoneMirroringTools`,
        `          driver=${result.stepResults[0]?.driver ?? "phone"} source=${read.source} rows=${preview.rows.length} grant=ui.read`,
      ],
    };
  } catch (error) {
    const code = errorCode(error);
    if (code === "accessibility" || code === "app_not_found") {
      return skipLines(lines, "iPhone Mirroring AX read skipped", code);
    }
    return { status: "fail", lines: [...lines, `probe     FAIL — ${code}`] };
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
