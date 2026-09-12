import { realpathSync } from "node:fs";
import { fileURLToPath, pathToFileURL } from "node:url";
import { proxyResponses } from "./gateway.ts";
import { allowGrant, grantableEffects, orchestrate } from "../../packages/ppomi-brain/src/index.ts";
import type {
  ActionEffect,
  BodyRunInput,
  BodyRunResult,
  BodyRuntime,
  BodyStepStatus,
  OrchestrationResult,
  PathDefinition,
  PathStep,
  SessionIdentity,
} from "../../packages/ppomi-brain/src/index.ts";
import {
  FixedPermissionGate,
  OsSurface,
  Runtime,
  type OsUiDriver,
  type Playbook,
  type PlaybookStep,
  type RunResult,
  type StepEffect,
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
  /**
   * Approval tokens for this one run (`<pathId>/<stepId>` for a commit step or a secrets read,
   * `live` for real-device arming). A token comes only from an explicit action — the 실행 button
   * in the window or `--approve` / `--live` on the CLI — never from the environment.
   */
  readonly approvals?: readonly string[];
}

/** What a gate is asking the person to allow; `token` is what an approving call passes back. */
export type GateEffect = "commit" | "secrets" | "live";

export interface ApprovalRequest {
  readonly pathId: string;
  readonly stepId: string;
  readonly effect: GateEffect;
  readonly title: string;
  readonly what: string;
  readonly token: string;
}

export const LIVE_APPROVAL_TOKEN = "live";

export interface SpineResult extends OrchestrationResult {
  readonly bodyKind: BodyKind;
  readonly live: boolean;
  readonly hook: string;
  /** The gate that stopped this run before anything executed; `null` when the run was not gated or was approved. */
  readonly approval: ApprovalRequest | null;
}

/** The only body effects a model-initiated run may perform on its own; anything else needs a token first. */
export const SAFE_EFFECTS: readonly StepEffect[] = ["navigate", "input"];

function isSafeEffect(effect: StepEffect | "read"): boolean {
  return effect === "read" || SAFE_EFFECTS.includes(effect);
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

/**
 * Brain effect → body effect. `lookup` is a read; `input`/`save` are declared mutations the
 * runtime may perform; `transmit` is a `commit` (the runtime hands it off unless a person approved
 * exactly that step); `financial_submit` is a `commit` no token can unlock — the brain never issues it.
 */
function lowerEffect(effect: ActionEffect): StepEffect | "read" {
  switch (effect) {
    case "lookup":
      return "read";
    case "input":
    case "save":
      return "input";
    case "transmit":
    case "financial_submit":
      return "commit";
    default: {
      const exhaustive: never = effect;
      return exhaustive;
    }
  }
}

function approvalToken(path: PathDefinition, step: PathStep): string {
  return `${path.id}/${step.id}`;
}

function gate(path: PathDefinition, step: PathStep, effect: GateEffect, what: string): ApprovalRequest {
  return { pathId: path.id, stepId: step.id, effect, title: step.title, what, token: effect === "live" ? LIVE_APPROVAL_TOKEN : approvalToken(path, step) };
}

/** Every gate on this run, in the order the person has to clear them. Empty for a safe path. */
export function gatesFor(path: PathDefinition, live: boolean): readonly ApprovalRequest[] {
  const gates: ApprovalRequest[] = [];
  const first = path.steps[0];
  if (path.id === secretsPath.id && first !== undefined) {
    gates.push(gate(path, first, "secrets", `Keychain / Credential Manager에서 ${KB_STAR_BIZ_ACCOUNT_KEY}를 읽어 마지막 4자리만 보여줍니다.`));
  }
  if (live && first !== undefined) {
    gates.push(gate(path, first, "live", `실기기 제어(live)로 「${path.title}」 경로를 실행합니다.`));
  }
  for (const step of path.steps) {
    if (!isSafeEffect(lowerEffect(step.effect)) && step.effect !== "financial_submit") {
      gates.push(gate(path, step, "commit", `「${step.title}」을(를) 실행합니다 — 되돌릴 수 없는 제출 단계입니다.`));
    }
  }
  return gates;
}

/** The first gate without a token. Nothing on the path runs while this is non-null. */
export function pendingGate(path: PathDefinition, live: boolean, approvals: readonly string[]): ApprovalRequest | null {
  return gatesFor(path, live).find(item => !approvals.includes(item.token)) ?? null;
}

/**
 * The playbook the runtime executes, lowered from the path's data. A commit step keeps
 * `effect: "commit"` — the runtime's own handoff — unless its exact token was approved, in which
 * case it becomes a declared `input` for this run only. `financial_submit` never lowers.
 */
function playbookFor(path: PathDefinition, approvals: readonly string[]): Playbook {
  const steps: PlaybookStep[] = path.steps.map(step => {
    const lowered = lowerEffect(step.effect);
    if (lowered === "read") return { id: step.id, kind: "read" };
    const approved = lowered === "commit" && step.effect !== "financial_submit" && approvals.includes(approvalToken(path, step));
    return { id: step.id, kind: "click", target: step.title, effect: approved ? "input" : lowered };
  });
  return { id: path.id, steps };
}

function approvedStepIds(path: PathDefinition, approvals: readonly string[]): ReadonlySet<string> {
  return new Set(path.steps.filter(step => approvals.includes(approvalToken(path, step))).map(step => step.id));
}

/** Stopped before anything ran: every step waits on the same gate. Never `completed`. */
function needsApproval(path: PathDefinition, pending: ApprovalRequest): BodyRunResult {
  return {
    status: "stopped",
    stopReason: "needs_human",
    steps: path.steps.map(step => ({
      stepId: step.id,
      effect: step.effect,
      status: "needs_human" as const,
      note: `needs_approval: ${pending.token} (${pending.effect}) — nothing executed`,
    })),
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

function toBodyResult(run: RunResult, path: PathDefinition, approved: ReadonlySet<string> = new Set()): BodyRunResult {
  const steps = path.steps.map((step, index) => {
    const row = run.stepResults[index];
    const note = row?.observation.summary ?? row?.code ?? "no step result";
    return {
      stepId: step.id,
      effect: step.effect,
      status: mapStatus(row?.status, row?.code),
      note: approved.has(step.id) ? `${note}; approved ${approvalToken(path, step)}` : note,
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
  approvals: readonly string[] = [],
): Promise<BodyRunResult> {
  const run = await new Runtime(
    new OsSurface(driver),
    new FixedPermissionGate(["ui.read", "ui.control"]),
  ).run(playbook);
  return toBodyResult(run, path, approvedStepIds(path, approvals));
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

async function runMacos(input: BodyRunInput, live: boolean, approvals: readonly string[]): Promise<BodyRunResult> {
  if (!live) {
    const window: FixtureMacosWindow = { ...demoWindow };
    return runDriver(
      input.path,
      new MacosDriver(new FixtureMacosNativeTools(window)),
      playbookFor(input.path, approvals),
      approvals,
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

async function runWindows(input: BodyRunInput, live: boolean, approvals: readonly string[]): Promise<BodyRunResult> {
  const window: FixtureWindowsWindow = { ...demoWindow, packageName: "win:1:1" };
  const result = await runDriver(
    input.path,
    new WindowsDriver(new FixtureWindowsExecutorTools(window)),
    playbookFor(input.path, approvals),
    approvals,
  );
  if (!live) return result;
  return withHook(result, "live windows is MZZ-55b — PPOMI_BODY_LIVE=1 node --experimental-strip-types packages/ppomi-body-windows/example/src/main.ts");
}

async function runAndroid(input: BodyRunInput, live: boolean, approvals: readonly string[]): Promise<BodyRunResult> {
  const window: FixtureAndroidWindow = { ...demoWindow, packageName: "com.ppomi.androidtarget" };
  const result = await runDriver(
    input.path,
    new AndroidDriver(new FixtureAndroidNativeTools(window)),
    playbookFor(input.path, approvals),
    approvals,
  );
  if (!live) return result;
  return withHook(result, "live android is MZZ-55c — PPOMI_BODY_LIVE=1 node --experimental-strip-types packages/ppomi-body-android/example/src/main.ts");
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

function runSecrets(path: PathDefinition, live: boolean): BodyRunResult {
  if (!liveSecretsRequested(live)) return fixtureSecrets(path);
  if (process.platform !== "darwin" && process.platform !== "win32") {
    return skipped(path, `live secrets skipped (no Keychain / Credential Manager on ${process.platform}). On a Mac: ${SECRETS_LIVE_HOOK}`);
  }
  try {
    const store = openOsSecretStore();
    return secretsResult(path, secretsNote(store.get(KB_STAR_BIZ_ACCOUNT_KEY)));
  } catch (error) {
    if (error instanceof SecretStoreError && error.code === "unavailable") {
      return skipped(path, `live secrets skipped (${error.message}). On a Mac: ${SECRETS_LIVE_HOOK}`);
    }
    const message = error instanceof Error ? error.message : String(error);
    return skipped(path, `live secrets skipped (${message}). On a Mac: ${SECRETS_LIVE_HOOK}`);
  }
}

interface GateCapture {
  approval: ApprovalRequest | null;
}

/**
 * The gate sits in front of every body, whoever asked (model function_call, local matcher, CLI):
 * a secrets read, a live run or a commit step stops the whole run before any step executes until
 * the matching token is presented. A safe path (navigate / input only, fixture) runs at once.
 */
function bodyFor(kind: BodyKind, live: boolean, approvals: readonly string[], capture: GateCapture): BodyRuntime {
  return {
    run(input) {
      const pending = pendingGate(input.path, live, approvals);
      if (pending !== null) {
        capture.approval = pending;
        return needsApproval(input.path, pending);
      }
      if (input.path.id === secretsPath.id) return runSecrets(input.path, live);
      switch (kind) {
        case "macos":
          return runMacos(input, live, approvals);
        case "windows":
          return runWindows(input, live, approvals);
        case "android":
          return runAndroid(input, live, approvals);
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

/**
 * `--approve <pathId>/<stepId>` (repeatable) clears one gate for this run. `--live` typed on the
 * command line is the person's own live approval; `PPOMI_BODY_LIVE=1` alone requests live but
 * approves nothing, so the run stops at the live gate instead of arming.
 */
export function parseArgs(argv: readonly string[]): SpineInput {
  let intent = "다음";
  let body = parseBodyKind(process.env.PPOMI_BODY);
  let live = process.env.PPOMI_BODY_LIVE === "1" || process.env.PPOMI_BODY_AX === "1";
  const approvals: string[] = [];
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
    if (arg === "--approve") {
      const value = argv[i + 1];
      if (value === undefined || value.length === 0) throw new Error("--approve needs <pathId>/<stepId> or live");
      approvals.push(value);
      i += 1;
      continue;
    }
    if (arg === "--live") {
      live = true;
      approvals.push(LIVE_APPROVAL_TOKEN);
      continue;
    }
    if (!arg.startsWith("-")) {
      intent = arg;
      continue;
    }
    throw new Error(`unknown argument: ${arg}`);
  }
  return { intent, body, live, approvals };
}

export interface SpineDeps {
  /** Catalog override for tests (a path with a commit step). Default: the built-in paths. */
  readonly paths?: readonly PathDefinition[];
}

export async function runSpine(input: SpineInput, deps: SpineDeps = {}): Promise<SpineResult> {
  const catalog = deps.paths ?? paths;
  const approvals = input.approvals ?? [];
  const capture: GateCapture = { approval: null };
  const result = await orchestrate(
    {
      paths: {
        list: () => catalog,
        load: (id: string) => catalog.find(path => path.id === id) ?? null,
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
      body: bodyFor(input.body, input.live, approvals, capture),
    },
    { text: input.intent, surface: "app" },
  );
  const hook = result.pathId === secretsPath.id ? SECRETS_LIVE_HOOK : hookFor(input.body);
  return { ...result, bodyKind: input.body, live: input.live, hook, approval: capture.approval };
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
