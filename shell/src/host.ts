import { realpathSync } from "node:fs";
import { fileURLToPath, pathToFileURL } from "node:url";
import { proxyResponses } from "./gateway.ts";
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
import {
  KB_STAR_BIZ_ACCOUNT_KEY,
  openOsSecretStore,
  secretEvidence,
  SecretStoreError,
} from "../../packages/ppomi-secrets/src/index.ts";
import { FakeSecretStore } from "../../packages/ppomi-secrets/src/testing.ts";

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

/** Probe digits only — same as ppomi-secrets example / Storybook. Never a real account. */
const SECRETS_FIXTURE_ACCOUNT = "001234567890";

export const secretsPath: PathDefinition = {
  id: "path-secrets-account",
  title: "사업자 계좌 시크릿",
  intents: [
    "사업자 계좌",
    "사업자 kb",
    "kb계좌",
    "kb 계좌",
    "kb account",
    "계좌번호",
    "통장번호",
    "account number",
    "account",
    "계좌",
  ],
  requiredEffects: ["lookup"],
  requiredSurfaces: ["app"],
  steps: [{ id: "read-account", title: "계좌번호 읽기", effect: "lookup" }],
};

const paths = [homePath, secretsPath];

export const SECRETS_LIVE_HOOK =
  "PPOMI_SECRETS_LIVE=1 npm --prefix shell run host -- --intent '내 사업자 KB계좌번호 알아?' --live";

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

function secretsNote(value: string | undefined): string {
  if (value === undefined) return `no secret for ${KB_STAR_BIZ_ACCOUNT_KEY}`;
  const evidence = secretEvidence(KB_STAR_BIZ_ACCOUNT_KEY, value);
  return `${evidence.masked} ${evidence.key}`;
}

function secretsResult(path: PathDefinition, note: string): BodyRunResult {
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

function fixtureSecrets(path: PathDefinition): BodyRunResult {
  // ponytail: in-process fixture, same as the secrets example. Keychain if --live / PPOMI_SECRETS_LIVE.
  const store = new FakeSecretStore();
  store.put(KB_STAR_BIZ_ACCOUNT_KEY, SECRETS_FIXTURE_ACCOUNT);
  return secretsResult(path, secretsNote(store.get(KB_STAR_BIZ_ACCOUNT_KEY)));
}

function liveSecretsRequested(live: boolean, env: NodeJS.ProcessEnv = process.env): boolean {
  return live || env.PPOMI_SECRETS_LIVE === "1";
}

/** A live read that cannot happen here is a stop the person sees, never a `completed` with no read behind it. */
function runSecrets(path: PathDefinition, live: boolean): BodyRunResult {
  if (!liveSecretsRequested(live)) return fixtureSecrets(path);
  if (process.platform !== "darwin" && process.platform !== "win32") {
    return stopped(path, "needs_human", `live secrets need a Mac or Windows (this is ${process.platform}); no Keychain / Credential Manager here. On a Mac: ${SECRETS_LIVE_HOOK}`);
  }
  try {
    const store = openOsSecretStore();
    return secretsResult(path, secretsNote(store.get(KB_STAR_BIZ_ACCOUNT_KEY)));
  } catch (error) {
    if (error instanceof SecretStoreError && error.code === "unavailable") {
      return stopped(path, "needs_human", `live secrets: store unavailable (${error.message}). On a Mac: ${SECRETS_LIVE_HOOK}`);
    }
    return failedWith(path, "live secrets failed:", error);
  }
}

function bodyFor(kind: BodyKind, live: boolean, capture: RunCapture): BodyRuntime {
  return {
    run(input) {
      if (input.path.id === secretsPath.id) return runSecrets(input.path, live);
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

/**
 * Live needs two keys: `--live` on the command line and `PPOMI_BODY_LIVE=1` in the environment.
 * The flag alone is refused (the person asked for live and must not get a fixture dressed as
 * one); the variable alone runs the fixture (a value inherited from some other probe's shell must
 * never arm anything). `PPOMI_BODY_AX` is the Mac package example's switch, not the shell's.
 */
export function parseArgs(argv: readonly string[], env: NodeJS.ProcessEnv = process.env): SpineInput {
  let intent = "다음";
  let body = parseBodyKind(env.PPOMI_BODY);
  let live = false;
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
  if (live && env.PPOMI_BODY_LIVE !== "1") {
    throw new Error("--live also needs PPOMI_BODY_LIVE=1 in the environment (PPOMI_BODY_AX does not arm the shell). Without --live the fixture runs.");
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
  const hook = result.pathId === secretsPath.id ? SECRETS_LIVE_HOOK : hookFor(input.body);
  return { ...result, bodyKind: input.body, live: input.live, hook, run: capture.run };
}

export { gatewayConfig, proxyResponses } from "./gateway.ts";

async function readStdinJson(): Promise<unknown> {
  const chunks: Buffer[] = [];
  for await (const chunk of process.stdin) chunks.push(chunk as Buffer);
  const raw = Buffer.concat(chunks).toString("utf8").trim();
  if (raw === "") return {};
  return JSON.parse(raw) as unknown;
}

function isMain(): boolean {
  const entry = process.argv[1];
  if (entry === undefined) return false;
  const self = fileURLToPath(import.meta.url);
  try {
    return realpathSync(entry) === realpathSync(self);
  } catch {
    return import.meta.url === pathToFileURL(entry).href;
  }
}

async function main(): Promise<void> {
  if (process.argv.includes("--proxy-responses")) {
    process.stdout.write(`${JSON.stringify(await proxyResponses(await readStdinJson()))}\n`);
    return;
  }
  const result = await runSpine(parseArgs(process.argv.slice(2)));
  process.stdout.write(`${JSON.stringify(result)}\n`);
}

// --proxy-responses must run even if isMain() misses a strip-types / symlink argv path.
if (process.argv.includes("--proxy-responses") || isMain()) {
  main().catch(error => {
    const message = error instanceof Error ? error.message : String(error);
    process.stderr.write(`${message}\n`);
    process.exitCode = 1;
  });
}
