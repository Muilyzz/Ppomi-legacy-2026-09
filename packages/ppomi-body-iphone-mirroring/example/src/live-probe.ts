import { spawnSync } from "node:child_process";
import { existsSync } from "node:fs";

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

function runOsascript(source: string): { ok: boolean; text: string } {
  const result = spawnSync("osascript", ["-e", source], { encoding: "utf8" });
  const text = `${result.stdout ?? ""}${result.stderr ?? ""}`.trim();
  return { ok: result.status === 0, text };
}

/** Activate iPhone Mirroring on Mac. Off-macOS or without PPOMI_BODY_LIVE=1 this skips. */
export function probeIphoneMirroringLive(): LiveProbe {
  const live = process.env.PPOMI_BODY_LIVE === "1";
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
    `live      ${live ? "PPOMI_BODY_LIVE=1" : "off (set PPOMI_BODY_LIVE=1 to activate iPhone Mirroring)"}`,
  ];

  if (!live) {
    return { status: "ok", lines: [...lines, "probe     dry-run — no AX / phone_*"] };
  }
  if (!installed) {
    return { status: "skip", lines: [...lines, "probe     SKIP — iPhone Mirroring.app missing"] };
  }

  const opened = runOsascript(`
tell application "iPhone Mirroring"
  activate
  delay 2
  if (count of windows) is 0 then error "no window"
  return name of front window
end tell
`);
  if (!opened.ok) {
    return {
      status: "skip",
      lines: [
        ...lines,
        "probe     SKIP — iPhone Mirroring Automation denied, no window, or phone not connected",
        `          ${opened.text}`,
      ],
    };
  }
  return { status: "ok", lines: [...lines, `probe     iPhone Mirroring window: ${opened.text}`] };
}

export function writeLiveProbe(probe: LiveProbe): void {
  const label = probe.status === "fail" ? "FAIL" : probe.status === "skip" ? "SKIP" : "PASS";
  process.stdout.write(`  live     ${label}\n`);
  for (const line of probe.lines) {
    process.stdout.write(`           ${line}\n`);
  }
  if (probe.status === "fail") process.exitCode = 1;
}
