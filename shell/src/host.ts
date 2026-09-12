import { pathToFileURL } from "node:url";
import { allowGrant, grantableEffects, orchestrate } from "../../packages/ppomi-brain/src/index.ts";
import type {
  BodyRunInput,
  BodyRunResult,
  BodyRuntime,
  BodyStepStatus,
  BodyStopReason,
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
  type StepResult,
  type StepResultStatus,
} from "../../packages/ppomi-body/src/index.ts";
import { redactText } from "../../packages/ppomi-body/src/public-url.ts";
import {
  FixtureMacosNativeTools,
  LiveMacosNativeTools,
  MacosDriver,
  macosBrowserApp,
  pickLiveAxClickTarget,
  type FixtureMacosWindow,
  type MacNativeTools,
} from "../../packages/ppomi-body-macos/src/index.ts";
import {
  FixtureWindowsExecutorTools,
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

export interface SpineInput {
  readonly intent: string;
  readonly body: BodyKind;
  readonly live: boolean;
}

export interface SpineResult extends OrchestrationResult {
  readonly bodyKind: BodyKind;
  readonly live: boolean;
  readonly hook: string;
  /** The core `RunResult` when the body reached `Runtime`; `null` when it stopped before that (refusal, skip, path miss). */
  readonly run: RunResult | null;
}

/** Live Mac tools as the spine uses them: `LiveMacosNativeTools`, or a test double off a Mac. */
export interface LiveMacTools extends MacNativeTools {
  readonly app: string;
  trusted(): boolean;
}

/** Filled by `runDriver` so the caller can return the core result next to the brain's summary. */
export interface RunCapture {
  run: RunResult | null;
}

const MACOS_LIVE_HOOK = "PPOMI_BODY_LIVE=1 npm --prefix shell run host -- --intent 다음 --body macos --live";
const WINDOWS_LIVE_HOOK = "PPOMI_BODY_LIVE=1 node --experimental-strip-types packages/ppomi-body-windows/example/src/main.ts";
const ANDROID_LIVE_HOOK = "PPOMI_BODY_LIVE=1 node --experimental-strip-types packages/ppomi-body-android/example/src/main.ts";

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

export const homePath: PathDefinition = {
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

/** The structured code leads the note so `stale_screen` / `protected_action` / `commit` survive the brain's flattening. */
function stepNote(row: StepResult | undefined): string {
  if (row === undefined) return "no step result";
  const summary = row.observation.summary;
  if (row.code === undefined) return summary;
  return summary.length > 0 ? `${row.code}: ${summary}` : row.code;
}

function toBodyResult(run: RunResult, path: PathDefinition): BodyRunResult {
  const invalid = run.status === "invalid" && run.invalid !== undefined
    ? `invalid: ${run.invalid.code} ${run.invalid.detail}`.trim()
    : null;
  const steps = path.steps.map(step => {
    const row = run.stepResults.find(item => item.stepId === step.id);
    return {
      stepId: step.id,
      effect: step.effect,
      status: mapStatus(row?.status, row?.code),
      note: invalid ?? stepNote(row),
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
  capture: RunCapture,
): Promise<BodyRunResult> {
  const run = await new Runtime(
    new OsSurface(driver),
    new FixedPermissionGate(["ui.read", "ui.control"]),
  ).run(playbook);
  capture.run = run;
  return toBodyResult(run, path);
}

/** The body stopped before `Runtime` ran anything: every declared step carries the reason. Never `completed`. */
function stopped(path: PathDefinition, reason: BodyStopReason, note: string): BodyRunResult {
  return {
    status: "stopped",
    stopReason: reason,
    steps: path.steps.map(step => ({
      stepId: step.id,
      effect: step.effect,
      status: reason,
      note,
    })),
  };
}

function failedWith(path: PathDefinition, prefix: string, error: unknown): BodyRunResult {
  const code = error instanceof Error && "code" in error && typeof error.code === "string" && error.code.length > 0
    ? error.code
    : "failed";
  const message = redactText(error instanceof Error ? error.message : String(error));
  return stopped(path, "failed", `${prefix} ${code}: ${message}`);
}

async function runMacos(input: BodyRunInput, live: boolean, capture: RunCapture): Promise<BodyRunResult> {
  if (!live) {
    const window: FixtureMacosWindow = { ...demoWindow };
    return runDriver(
      input.path,
      new MacosDriver(new FixtureMacosNativeTools(window)),
      fixturePlaybook(input.path),
      capture,
    );
  }
  if (process.platform !== "darwin") {
    return stopped(input.path, "needs_human", `live macos needs a Mac (this is ${process.platform}). On a Mac: ${MACOS_LIVE_HOOK}`);
  }
  const preferred = process.env.PPOMI_MAC_BROWSER === "chrome" ? "chrome" : "safari";
  const app = macosBrowserApp(preferred);
  if (app === null) {
    return stopped(input.path, "needs_human", "live macos needs Safari or Chrome (PPOMI_MAC_BROWSER=safari|chrome)");
  }
  let tools: LiveMacTools;
  try {
    tools = new LiveMacosNativeTools({ app });
  } catch (error) {
    return failedWith(input.path, "live macos could not start:", error);
  }
  return runLiveMacos(input.path, tools, capture);
}

/**
 * The live Mac sequence: Accessibility check, open example.com, read, pick only the
 * "More information" link, then one gated `Runtime` click. Denied Accessibility is
 * `grant_denied`, a missing link is `needs_human`, a thrown tool error is `failed`;
 * `completed` only comes out of `Runtime`.
 */
export async function runLiveMacos(path: PathDefinition, tools: LiveMacTools, capture: RunCapture): Promise<BodyRunResult> {
  if (!tools.trusted()) {
    return stopped(path, "grant_denied", "live macos: Accessibility denied. Grant 손쉬운 사용 to the terminal or 뽀미.app, then rerun --live.");
  }
  let node;
  try {
    tools.browser_open({ app: tools.app, url: "https://example.com/" });
    node = pickLiveAxClickTarget(tools.screen_read().nodes);
  } catch (error) {
    return failedWith(path, "live macos failed before the click:", error);
  }
  if (node === undefined) {
    return stopped(path, "needs_human", `live macos: example.com "More information" is not on the ${tools.app} front window; nothing else is clicked.`);
  }
  return runDriver(
    path,
    new MacosDriver(tools),
    { id: path.id, steps: [{ id: "open-next", kind: "click", target: node.text, effect: "navigate" }] },
    capture,
  );
}

async function runWindows(input: BodyRunInput, live: boolean, capture: RunCapture): Promise<BodyRunResult> {
  if (live) {
    return stopped(input.path, "failed", `live windows is not wired through the shell (MZZ-55b); the fixture runs without --live. Live UIA: ${WINDOWS_LIVE_HOOK}`);
  }
  const window: FixtureWindowsWindow = { ...demoWindow, packageName: "win:1:1" };
  return runDriver(
    input.path,
    new WindowsDriver(new FixtureWindowsExecutorTools(window)),
    fixturePlaybook(input.path),
    capture,
  );
}

async function runAndroid(input: BodyRunInput, live: boolean, capture: RunCapture): Promise<BodyRunResult> {
  if (live) {
    return stopped(input.path, "failed", `live android is not wired through the shell (MZZ-55c); the fixture runs without --live. Live UIAutomator: ${ANDROID_LIVE_HOOK}`);
  }
  const window: FixtureAndroidWindow = { ...demoWindow, packageName: "com.ppomi.androidtarget" };
  return runDriver(
    input.path,
    new AndroidDriver(new FixtureAndroidNativeTools(window)),
    fixturePlaybook(input.path),
    capture,
  );
}

function bodyFor(kind: BodyKind, live: boolean, capture: RunCapture): BodyRuntime {
  return {
    run(input) {
      switch (kind) {
        case "macos":
          return runMacos(input, live, capture);
        case "windows":
          return runWindows(input, live, capture);
        case "android":
          return runAndroid(input, live, capture);
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
      return MACOS_LIVE_HOOK;
    case "windows":
      return WINDOWS_LIVE_HOOK;
    case "android":
      return ANDROID_LIVE_HOOK;
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
  const capture: RunCapture = { run: null };
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
      body: bodyFor(input.body, input.live, capture),
    },
    { text: input.intent, surface: "app" },
  );
  return { ...result, bodyKind: input.body, live: input.live, hook: hookFor(input.body), run: capture.run };
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
