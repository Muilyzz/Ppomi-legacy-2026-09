import {
  FixedPermissionGate,
  OsSurface,
  Runtime,
  type Playbook,
} from "../../../ppomi-body/src/index.ts";
import {
  AndroidAdapterError,
  AndroidDriver,
  LiveAndroidNativeTools,
  listAdbDevices,
  liveAndroidClickLabel,
  liveAndroidRequested,
  pickLiveAndroidClickTarget,
  resolveAdbSerial,
} from "../../src/index.ts";

const LIVE_COMMAND =
  "PPOMI_BODY_LIVE=1 node --experimental-strip-types packages/ppomi-body-android/example/src/main.ts";

export type LiveProbeStatus = "ok" | "skip" | "fail";

export interface LiveProbe {
  readonly status: LiveProbeStatus;
  readonly lines: readonly string[];
}

function skipLines(lines: readonly string[], detail: string, extra?: string): LiveProbe {
  const out = [...lines, `uia       SKIP — ${detail}`];
  if (extra !== undefined && extra.length > 0) out.push(`          ${extra}`);
  return { status: "skip", lines: out };
}

function errorCode(error: unknown): string {
  if (error instanceof AndroidAdapterError) return error.code;
  return error instanceof Error ? error.message : String(error);
}

/** Live dump+tap 1-step through AndroidDriver. No adb / no device / no env → skip (exit 0). */
export async function probeAndroidLive(): Promise<LiveProbe> {
  const live = liveAndroidRequested();
  const { missing, serials } = listAdbDevices();
  const pinned = process.env.ANDROID_SERIAL ?? process.env.PPOMI_ANDROID_SERIAL;
  const lines = [
    `platform  ${process.platform}`,
    `adb       ${missing ? "(not on PATH)" : serials.length > 0 ? serials.join(",") : "(no device)"}`,
    `live      ${live ? "PPOMI_BODY_LIVE=1" : "off (set PPOMI_BODY_LIVE=1 with a connected device)"}`,
  ];

  if (!live) {
    return {
      status: "ok",
      lines: [...lines, "uia       dry-run — fixture only, no uiautomator dump / tap", `          ${LIVE_COMMAND}`],
    };
  }
  if (missing) return skipLines(lines, "adb not on PATH");
  const resolved = resolveAdbSerial(serials, pinned);
  if (resolved.serial === undefined) {
    if (resolved.code === "multiple_devices") {
      return skipLines(lines, "multiple devices; set ANDROID_SERIAL or PPOMI_ANDROID_SERIAL");
    }
    return skipLines(lines, "no authorized Android device");
  }

  const serial = resolved.serial;
  const tools = new LiveAndroidNativeTools({ serial });

  try {
    tools.android_open({ packageName: "com.android.settings" });
  } catch (error) {
    return skipLines(lines, `Settings launch failed on ${serial}`, errorCode(error));
  }

  let preview;
  try {
    preview = tools.android_screen();
  } catch (error) {
    const code = errorCode(error);
    if (code === "no_adb" || code === "no_device") return skipLines(lines, `dump skipped on ${serial}`, code);
    return { status: "fail", lines: [...lines, `uia       FAIL — android_screen ${code}`] };
  }

  const node = pickLiveAndroidClickTarget(preview.nodes);
  if (node === undefined) {
    return skipLines(
      lines,
      `front dump is not Settings or has no 연결/Wi-Fi row — nothing else is clicked`,
      `nodes=${preview.nodes.length}`,
    );
  }

  const target = liveAndroidClickLabel(node);
  const oneStep: Playbook = {
    id: "android-live-uia-1-step",
    steps: [{ id: "uia-click", kind: "click", target, effect: "navigate" }],
  };

  try {
    const result = await new Runtime(
      new OsSurface(new AndroidDriver(tools)),
      new FixedPermissionGate(["ui.read", "ui.control"]),
    ).run(oneStep);
    if (result.status !== "completed" || result.stepResults[0]?.status !== "ok") {
      return {
        status: "fail",
        lines: [
          ...lines,
          `uia       FAIL — Runtime ${result.status} ${result.stepResults[0]?.code ?? "?"}`,
        ],
      };
    }
    return {
      status: "ok",
      lines: [
        ...lines,
        `uia       ${serial} click "${target}" via AndroidDriver + LiveAndroidNativeTools (uiautomator dump + tap)`,
        `          driver=${result.stepResults[0]?.driver ?? "os-android"} nodes=${preview.nodes.length}`,
      ],
    };
  } catch (error) {
    const code = errorCode(error);
    if (code === "no_adb" || code === "no_device") return skipLines(lines, `tap skipped on ${serial}`, code);
    return { status: "fail", lines: [...lines, `uia       FAIL — ${code}`] };
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
