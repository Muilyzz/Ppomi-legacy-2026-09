import { spawnSync } from "node:child_process";

const LIVE_COMMAND =
  "PPOMI_BODY_LIVE=1 node --experimental-strip-types packages/ppomi-body-android/example/src/main.ts";

export type LiveProbeStatus = "ok" | "skip" | "fail";

export interface LiveProbe {
  readonly status: LiveProbeStatus;
  readonly lines: readonly string[];
}

function runAdb(args: readonly string[]): { ok: boolean; text: string; missing: boolean } {
  const result = spawnSync("adb", [...args], { encoding: "utf8" });
  const missing = result.error !== undefined && "code" in result.error && result.error.code === "ENOENT";
  const text = `${result.stdout ?? ""}${result.stderr ?? ""}`.trim();
  return { ok: result.status === 0 && !missing, text, missing };
}

function connectedSerials(): { missing: boolean; serials: string[] } {
  const listed = runAdb(["devices"]);
  if (listed.missing) return { missing: true, serials: [] };
  const serials = listed.text
    .split(/\r?\n/)
    .slice(1)
    .map(line => line.trim())
    .filter(line => /\tdevice$/.test(line))
    .map(line => line.split(/\s+/)[0] ?? "")
    .filter(serial => serial.length > 0);
  return { missing: false, serials };
}

/** Open Settings on a connected device. No ADB / no device / without PPOMI_BODY_LIVE=1 this skips. */
export function probeAndroidLive(): LiveProbe {
  const live = process.env.PPOMI_BODY_LIVE === "1";
  const { missing, serials } = connectedSerials();
  const pinned = process.env.ANDROID_SERIAL ?? process.env.PPOMI_ANDROID_SERIAL;
  const lines = [
    `platform  ${process.platform}`,
    `adb       ${missing ? "(not on PATH)" : serials.length > 0 ? serials.join(",") : "(no device)"}`,
    `live      ${live ? "PPOMI_BODY_LIVE=1" : "off (set PPOMI_BODY_LIVE=1 with a connected device)"}`,
  ];

  if (!live) {
    return {
      status: "ok",
      lines: [...lines, "probe     dry-run — no Settings launch", `          ${LIVE_COMMAND}`],
    };
  }
  if (missing) {
    return { status: "skip", lines: [...lines, "probe     SKIP — adb not on PATH"] };
  }
  if (serials.length === 0) {
    return { status: "skip", lines: [...lines, "probe     SKIP — no authorized Android device"] };
  }
  if (serials.length > 1 && (pinned === undefined || !serials.includes(pinned))) {
    return {
      status: "skip",
      lines: [...lines, "probe     SKIP — multiple devices; set ANDROID_SERIAL or PPOMI_ANDROID_SERIAL"],
    };
  }

  const serial = pinned !== undefined && serials.includes(pinned) ? pinned : serials[0]!;
  const opened = runAdb(["-s", serial, "shell", "am", "start", "-a", "android.settings.SETTINGS"]);
  if (!opened.ok) {
    return {
      status: "skip",
      lines: [...lines, `probe     SKIP — Settings launch failed on ${serial}`, `          ${opened.text}`],
    };
  }
  return { status: "ok", lines: [...lines, `probe     Settings opened on ${serial}`] };
}

export function writeLiveProbe(probe: LiveProbe): void {
  const label = probe.status === "fail" ? "FAIL" : probe.status === "skip" ? "SKIP" : "PASS";
  process.stdout.write(`  live     ${label}\n`);
  for (const line of probe.lines) {
    process.stdout.write(`           ${line}\n`);
  }
  if (probe.status === "fail") process.exitCode = 1;
}
