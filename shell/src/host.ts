import { existsSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
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
  LiveWindowsExecutorTools,
  WindowsDriver,
  type FixtureWindowsWindow,
} from "../../packages/ppomi-body-windows/src/index.ts";
import {
  AndroidDriver,
  FixtureAndroidNativeTools,
  type FixtureAndroidWindow,
} from "../../packages/ppomi-body-android/src/index.ts";

export const BODY_KINDS = ["macos", "windows", "android"] as const;
export type BodyKind = (typeof BODY_KINDS)[number];

const repoRoot = join(dirname(fileURLToPath(import.meta.url)), "..", "..");
const LIVE_WINDOWS_HOST =
  "PPOMI_BODY_LIVE=1 npm --prefix shell run host -- --intent 다음 --body windows --live";
const LIVE_WINDOWS_EXAMPLE =
  "PPOMI_BODY_LIVE=1 node --experimental-strip-types packages/ppomi-body-windows/example/src/main.ts";

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

function windowsExecutorPath(): string {
  return process.env.PPOMI_EXECUTOR
    ?? join(repoRoot, "shell", "src-tauri", "resources", "executor", "ppomi-executor.exe");
}

async function runWindowsLive(input: BodyRunInput): Promise<BodyRunResult> {
  const fake = process.env.PPOMI_WINDOWS_FAKE_EXECUTOR;
  if (fake !== undefined && fake !== "") {
    const tools = LiveWindowsExecutorTools.start({
      executorPath: "unused-when-launch-is-given",
      launch: { command: process.execPath, args: [fake] },
    });
    try {
      const app = tools.listApps("").apps[0];
      if (app === undefined) {
        return skipped(input.path, "live windows fake executor listed no app");
      }
      tools.allowApps([app.packageName]);
      return runDriver(input.path, new WindowsDriver(tools), {
        id: input.path.id,
        steps: [{ id: "open-next", kind: "click", target: "Go", effect: "navigate" }],
      });
    } finally {
      tools.close();
    }
  }

  if (process.platform !== "win32") {
    return skipped(
      input.path,
      `live windows skipped (not win32). On Windows: ${LIVE_WINDOWS_HOST} — needs ppomi-executor + Edge; UAC/UIA grant is human. Package probe: ${LIVE_WINDOWS_EXAMPLE}`,
    );
  }

  const executor = windowsExecutorPath();
  if (!existsSync(executor)) {
    return skipped(
      input.path,
      `live windows skipped (no ppomi-executor). Set PPOMI_EXECUTOR. UAC/UIA is human. Then: ${LIVE_WINDOWS_HOST} or ${LIVE_WINDOWS_EXAMPLE}`,
    );
  }

  try {
    const tools = LiveWindowsExecutorTools.start({ executorPath: executor });
    try {
      const apps = tools.listApps("").apps;
      return skipped(
        input.path,
        `live windows executor reachable (${apps.length} apps). Isolated Edge UIA is human/UAC — ${LIVE_WINDOWS_EXAMPLE}`,
      );
    } finally {
      tools.close();
    }
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    return skipped(input.path, `live windows executor start failed (${message}). UAC? ${LIVE_WINDOWS_EXAMPLE}`);
  }
}

async function runWindows(input: BodyRunInput, live: boolean): Promise<BodyRunResult> {
  if (!live) {
    const window: FixtureWindowsWindow = { ...demoWindow, packageName: "win:1:1" };
    return runDriver(
      input.path,
      new WindowsDriver(new FixtureWindowsExecutorTools(window)),
      fixturePlaybook(input.path),
    );
  }
  return runWindowsLive(input);
}

async function runAndroid(input: BodyRunInput, live: boolean): Promise<BodyRunResult> {
  const window: FixtureAndroidWindow = { ...demoWindow, packageName: "com.ppomi.androidtarget" };
  const result = await runDriver(
    input.path,
    new AndroidDriver(new FixtureAndroidNativeTools(window)),
    fixturePlaybook(input.path),
  );
  if (!live) return result;
  return withHook(result, "live android is MZZ-55c — PPOMI_BODY_LIVE=1 node --experimental-strip-types packages/ppomi-body-android/example/src/main.ts");
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
      return LIVE_WINDOWS_HOST;
    case "android":
      return "PPOMI_BODY_LIVE=1 node --experimental-strip-types packages/ppomi-body-android/example/src/main.ts";
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
