import { pathToFileURL } from "node:url";
import { allowGrant, grantableEffects, orchestrate } from "../../packages/ppomi-brain/src/index.ts";
import type {
  BodyRunInput,
  BodyRunResult,
  BodyRuntime,
  BodyStepStatus,
  OrchestrationResult,
  PathDefinition,
  SessionIdentity,
} from "../../packages/ppomi-brain/src/index.ts";
import {
  FixedPermissionGate,
  OsSurface,
  Runtime,
  type OsUiDriver,
  type Playbook,
  type RunResult,
  type StepResultStatus,
} from "../../packages/ppomi-body/src/index.ts";
import {
  FixtureMacosNativeTools,
  LiveMacosNativeTools,
  MacosDriver,
  macosBrowserApp,
  pickLiveAxClickTarget,
  type FixtureMacosWindow,
} from "../../packages/ppomi-body-macos/src/index.ts";
import {
  FixtureWindowsExecutorTools,
  WindowsDriver,
  type FixtureWindowsWindow,
} from "../../packages/ppomi-body-windows/src/index.ts";
import {
  AndroidAdapterError,
  AndroidDriver,
  FixtureAndroidNativeTools,
  LiveAndroidNativeTools,
  listAdbDevices,
  liveAndroidClickLabel,
  pickLiveAndroidClickTarget,
  resolveAdbSerial,
  type FixtureAndroidWindow,
} from "../../packages/ppomi-body-android/src/index.ts";

export const BODY_KINDS = ["macos", "windows", "android"] as const;
export type BodyKind = (typeof BODY_KINDS)[number];

export interface SpineInput {
  readonly intent: string;
  readonly body: BodyKind;
  readonly live: boolean;
}

export interface SpineResult extends OrchestrationResult {
  readonly bodyKind: BodyKind;
  readonly live: boolean;
  readonly hook: string;
}

const identity: SessionIdentity = {
  ownerId: "shell-dev",
  orgId: "local",
  seatId: "seat-1",
};

const demoWindow = {
  appLabel: "Demo App",
  nodes: [
    { text: "Demo App", clickable: false, editable: false },
    { text: "Next", clickable: true, editable: false },
  ],
} as const;

const homePath: PathDefinition = {
  id: "path-home-next",
  title: "Home next",
  intents: ["browse", "next", "다음", "열어", "home"],
  requiredEffects: ["input"],
  requiredSurfaces: ["app"],
  steps: [{ id: "open-next", title: "Next", effect: "input" }],
};

const paths = [homePath];

function fixturePlaybook(path: PathDefinition): Playbook {
  return {
    id: path.id,
    steps: [{ id: "open-next", kind: "click", target: "Next", effect: "navigate" }],
  };
}

function mapStatus(status: StepResultStatus | undefined, code: string | undefined): BodyStepStatus {
  if (code === "permission_denied") return "grant_denied";
  switch (status) {
    case "ok":
      return "ok";
    case "needs_human":
      return "needs_human";
    case "protected":
      return "protected";
    case undefined:
    case "retryable":
    case "ambiguous":
    case "failed":
      return "failed";
    default: {
      const exhaustive: never = status;
      return exhaustive;
    }
  }
}

function toBodyResult(run: RunResult, path: PathDefinition): BodyRunResult {
  const steps = path.steps.map((step, index) => {
    const row = run.stepResults[index];
    return {
      stepId: step.id,
      effect: step.effect,
      status: mapStatus(row?.status, row?.code),
      note: row?.observation.summary ?? row?.code ?? "no step result",
    };
  });
  const blocking = steps.find(step => step.status !== "ok");
  if (blocking !== undefined && blocking.status !== "ok") {
    return { status: "stopped", stopReason: blocking.status, steps };
  }
  if (run.status === "completed") {
    return { status: "completed", stopReason: null, steps };
  }
  return { status: "stopped", stopReason: "failed", steps };
}

async function runDriver(
  path: PathDefinition,
  driver: OsUiDriver,
  playbook: Playbook,
): Promise<BodyRunResult> {
  const run = await new Runtime(
    new OsSurface(driver),
    new FixedPermissionGate(["ui.read", "ui.control"]),
  ).run(playbook);
  return toBodyResult(run, path);
}

function skipped(path: PathDefinition, note: string): BodyRunResult {
  return {
    status: "completed",
    stopReason: null,
    steps: path.steps.map(step => ({
      stepId: step.id,
      effect: step.effect,
      status: "ok" as const,
      note,
    })),
  };
}

async function runMacos(input: BodyRunInput, live: boolean): Promise<BodyRunResult> {
  if (!live) {
    const window: FixtureMacosWindow = { ...demoWindow };
    return runDriver(
      input.path,
      new MacosDriver(new FixtureMacosNativeTools(window)),
      fixturePlaybook(input.path),
    );
  }
  if (process.platform !== "darwin") {
    return skipped(input.path, "live macos skipped (not darwin). On a Mac: PPOMI_BODY_LIVE=1 npm --prefix shell run host -- --intent 다음 --body macos --live");
  }
  const preferred = process.env.PPOMI_MAC_BROWSER === "chrome" ? "chrome" : "safari";
  const app = macosBrowserApp(preferred);
  if (app === null) {
    return skipped(input.path, "live macos skipped (no Safari/Chrome name)");
  }
  const tools = new LiveMacosNativeTools({ app });
  if (!tools.trusted()) {
    return skipped(input.path, "live macos skipped (Accessibility denied). Grant 손쉬운 사용 to the terminal or Ppomi.app, then rerun --live.");
  }
  try {
    tools.browser_open({ app, url: "https://example.com/" });
    const preview = tools.screen_read();
    const node = pickLiveAxClickTarget(preview.nodes);
    if (node === undefined) {
      return skipped(input.path, "live macos skipped (example.com More information not on the front window)");
    }
    return runDriver(input.path, new MacosDriver(tools), {
      id: input.path.id,
      steps: [{ id: "open-next", kind: "click", target: node.text, effect: "navigate" }],
    });
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    return skipped(input.path, `live macos skipped (${message})`);
  }
}

function withHook(result: BodyRunResult, note: string): BodyRunResult {
  const last = result.steps.at(-1);
  if (last === undefined) return result;
  return {
    ...result,
    steps: [...result.steps.slice(0, -1), { ...last, note: `${last.note}; ${note}` }],
  };
}

async function runWindows(input: BodyRunInput, live: boolean): Promise<BodyRunResult> {
  const window: FixtureWindowsWindow = { ...demoWindow, packageName: "win:1:1" };
  const result = await runDriver(
    input.path,
    new WindowsDriver(new FixtureWindowsExecutorTools(window)),
    fixturePlaybook(input.path),
  );
  if (!live) return result;
  return withHook(result, "live windows is MZZ-55b — PPOMI_BODY_LIVE=1 node --experimental-strip-types packages/ppomi-body-windows/example/src/main.ts");
}

async function runAndroid(input: BodyRunInput, live: boolean): Promise<BodyRunResult> {
  if (!live) {
    const window: FixtureAndroidWindow = { ...demoWindow, packageName: "com.ppomi.androidtarget" };
    return runDriver(
      input.path,
      new AndroidDriver(new FixtureAndroidNativeTools(window)),
      fixturePlaybook(input.path),
    );
  }
  const { missing, serials } = listAdbDevices();
  if (missing) {
    return skipped(
      input.path,
      "live android skipped (adb not on PATH). Boot an emulator, pin it, then: PPOMI_ANDROID_SERIAL=emulator-5554 PPOMI_BODY_LIVE=1 npm --prefix shell run host -- --intent 다음 --body android --live",
    );
  }
  const pinned = process.env.ANDROID_SERIAL ?? process.env.PPOMI_ANDROID_SERIAL;
  const resolved = resolveAdbSerial(serials, pinned);
  if (resolved.serial === undefined) {
    if (resolved.code === "serial_required") {
      return skipped(
        input.path,
        "live android skipped (set PPOMI_ANDROID_SERIAL or ANDROID_SERIAL). Emulator: scripts/android-emulator.sh boot, then pin emulator-5554. A single attached device is never auto-targeted.",
      );
    }
    return skipped(input.path, "live android skipped (pinned serial is not an authorized attached device)");
  }
  const tools = new LiveAndroidNativeTools({ serial: resolved.serial });
  try {
    tools.android_open({ packageName: "com.android.settings" });
    const preview = tools.android_screen();
    const node = pickLiveAndroidClickTarget(preview.nodes);
    if (node === undefined) {
      return skipped(
        input.path,
        "live android skipped (no safe Settings row — 연결 / Wi-Fi / 블루투스 / 알림 / 배터리 / 디스플레이). Nothing else is tapped.",
      );
    }
    return runDriver(input.path, new AndroidDriver(tools), {
      id: input.path.id,
      steps: [{ id: "open-next", kind: "click", target: liveAndroidClickLabel(node), effect: "navigate" }],
    });
  } catch (error) {
    const code = error instanceof AndroidAdapterError ? error.code : "";
    if (code === "no_adb" || code === "no_device") {
      return skipped(input.path, `live android skipped (${code})`);
    }
    const message = error instanceof Error ? error.message : String(error);
    return skipped(input.path, `live android skipped (${message})`);
  }
}

function bodyFor(kind: BodyKind, live: boolean): BodyRuntime {
  return {
    run(input) {
      switch (kind) {
        case "macos":
          return runMacos(input, live);
        case "windows":
          return runWindows(input, live);
        case "android":
          return runAndroid(input, live);
        default: {
          const exhaustive: never = kind;
          return exhaustive;
        }
      }
    },
  };
}

function hookFor(kind: BodyKind): string {
  switch (kind) {
    case "macos":
      return "PPOMI_BODY_LIVE=1 npm --prefix shell run host -- --intent 다음 --body macos --live";
    case "windows":
      return "PPOMI_BODY_LIVE=1 node --experimental-strip-types packages/ppomi-body-windows/example/src/main.ts";
    case "android":
      return "PPOMI_ANDROID_SERIAL=emulator-5554 PPOMI_BODY_LIVE=1 npm --prefix shell run host -- --intent 다음 --body android --live";
    default: {
      const exhaustive: never = kind;
      return exhaustive;
    }
  }
}

export function parseBodyKind(value: string | undefined): BodyKind {
  switch (value) {
    case undefined:
    case "":
    case "macos":
      return "macos";
    case "windows":
    case "android":
      return value;
    default:
      throw new Error(`body must be macos | windows | android (got ${value})`);
  }
}

export function parseArgs(argv: readonly string[]): SpineInput {
  let intent = "다음";
  let body = parseBodyKind(process.env.PPOMI_BODY);
  let live = process.env.PPOMI_BODY_LIVE === "1" || process.env.PPOMI_BODY_AX === "1";
  for (let i = 0; i < argv.length; i += 1) {
    const arg = argv[i];
    if (arg === "--intent") {
      const value = argv[i + 1];
      if (value === undefined) throw new Error("--intent needs text");
      intent = value;
      i += 1;
      continue;
    }
    if (arg === "--body") {
      body = parseBodyKind(argv[i + 1]);
      i += 1;
      continue;
    }
    if (arg === "--live") {
      live = true;
      continue;
    }
    if (!arg.startsWith("-")) {
      intent = arg;
      continue;
    }
    throw new Error(`unknown argument: ${arg}`);
  }
  return { intent, body, live };
}

export async function runSpine(input: SpineInput): Promise<SpineResult> {
  const result = await orchestrate(
    {
      paths: {
        list: () => paths,
        load: (id: string) => paths.find(path => path.id === id) ?? null,
      },
      session: {
        current: () => identity,
        grantFor: (path: PathDefinition) => allowGrant({
          pathId: path.id,
          ownerId: identity.ownerId,
          effects: grantableEffects(path.requiredEffects),
          surfaces: path.requiredSurfaces,
          ...(identity.orgId !== undefined ? { orgId: identity.orgId } : {}),
          ...(identity.seatId !== undefined ? { seatId: identity.seatId } : {}),
        }),
      },
      body: bodyFor(input.body, input.live),
    },
    { text: input.intent, surface: "app" },
  );
  return { ...result, bodyKind: input.body, live: input.live, hook: hookFor(input.body) };
}

function isMain(): boolean {
  const entry = process.argv[1];
  if (entry === undefined) return false;
  return import.meta.url === pathToFileURL(entry).href;
}

async function main(): Promise<void> {
  const result = await runSpine(parseArgs(process.argv.slice(2)));
  process.stdout.write(`${JSON.stringify(result)}\n`);
  if (result.status === "path_not_found" || result.status === "grant_denied" || result.status === "failed") {
    process.exitCode = 1;
  }
}

if (isMain()) {
  main().catch(error => {
    const message = error instanceof Error ? error.message : String(error);
    process.stderr.write(`${message}\n`);
    process.exitCode = 1;
  });
}
