import { spawnSync } from "node:child_process";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import {
  MACOS_SNAPSHOT_TTL_MS,
  MacosAdapterError,
  isMacosPayWord,
  macosBrowserApp,
  type MacNativeTools,
  type MacScreenBounds,
  type MacScreenNode,
  type MacScreenRead,
} from "./macos-native-tools.ts";

const SCRIPT = join(dirname(fileURLToPath(import.meta.url)), "ax-jxa.js");

export interface LiveAxNode {
  readonly text: string;
  readonly role: string;
  readonly clickable: boolean;
  readonly editable: boolean;
  readonly password: boolean;
  readonly web: boolean;
  readonly bounds: { left: number; top: number; right: number; bottom: number };
}

/**
 * `tap` / `type` carry the read-time identity (`role`, `label`) of the node they were checked
 * against, never coordinates: the script re-resolves the element live, refuses with `stale_screen`
 * when role/text no longer match or the element has no frame, and clicks the live frame only.
 */
export type LiveMacosCommand =
  | { readonly op: "trusted" }
  | { readonly op: "open"; readonly app: string; readonly url?: string }
  | { readonly op: "read"; readonly app: string }
  | {
      readonly op: "tap";
      readonly app: string;
      readonly index: number;
      readonly web: boolean;
      readonly role: string;
      readonly label: string;
    }
  | {
      readonly op: "type";
      readonly app: string;
      readonly index: number;
      readonly role: string;
      readonly label: string;
      readonly text: string;
    };

export interface LiveMacosOk {
  readonly ok: true;
  readonly result: {
    readonly trusted?: boolean;
    readonly opened?: boolean;
    readonly app?: string;
    readonly appLabel?: string;
    readonly packageName?: string;
    readonly truncated?: boolean;
    readonly nodes?: readonly LiveAxNode[];
    readonly invoked?: boolean;
    readonly typed?: boolean;
  };
}

export interface LiveMacosErr {
  readonly ok: false;
  readonly code: string;
  readonly message: string;
}

export type LiveMacosReply = LiveMacosOk | LiveMacosErr;
export type LiveMacosExec = (command: LiveMacosCommand) => LiveMacosReply;

export interface LiveMacosNativeToolsOptions {
  readonly app?: string;
  readonly exec?: LiveMacosExec;
  readonly now?: () => number;
  readonly snapshotTtlMs?: number;
}

interface StoredNode extends MacScreenNode {
  readonly index: number;
  readonly password: boolean;
  readonly web: boolean;
  readonly role: string;
  readonly bounds: MacScreenBounds;
}

/** Every C0/C1 control except `\t`, like `MacUI.parseType`: a typed `\n` would be Return (submit). */
const CONTROL_CHARS = /[\u0000-\u0008\u000A-\u001F\u007F-\u009F]/;

/**
 * `MacNativeTools` over live macOS Accessibility (System Events / AX).
 * Contract matches `MacUI.swift`: snapshot ids die after tap/type or 15s;
 * payment labels and password fields are `protected_action`.
 */
export class LiveMacosNativeTools implements MacNativeTools {
  readonly app: string;
  private readonly exec: LiveMacosExec;
  private readonly now: () => number;
  private readonly snapshotTtlMs: number;
  private reads = 0;
  private stored: { snapshotId: string; at: number; nodes: StoredNode[] } | null = null;

  constructor(options: LiveMacosNativeToolsOptions = {}) {
    const app = macosBrowserApp(options.app ?? "Safari");
    if (app === null) throw new MacosAdapterError("app_not_found", `unsupported app: ${options.app ?? ""}`);
    this.app = app;
    this.exec = options.exec ?? defaultExec(SCRIPT);
    this.now = options.now ?? Date.now;
    this.snapshotTtlMs = options.snapshotTtlMs ?? MACOS_SNAPSHOT_TTL_MS;
  }

  trusted(): boolean {
    const reply = this.exec({ op: "trusted" });
    return reply.ok && reply.result.trusted === true;
  }

  browser_open(args: { app?: string; url?: string }): { opened: boolean; app: string } {
    const app = args.app !== undefined ? macosBrowserApp(args.app) : this.app;
    if (app === null) throw new MacosAdapterError("app_not_found", `app_not_found. ${args.app ?? ""}`);
    const command: LiveMacosCommand = args.url === undefined
      ? { op: "open", app }
      : { op: "open", app, url: args.url };
    const reply = this.exec(command);
    if (!reply.ok) throw liveError(reply);
    this.stored = null;
    return { opened: true, app };
  }

  screen_read(): MacScreenRead {
    const reply = this.exec({ op: "read", app: this.app });
    if (!reply.ok) throw liveError(reply);
    this.reads += 1;
    const snapshotId = `ax-${this.reads}`;
    const raw = reply.result.nodes ?? [];
    const nodes: StoredNode[] = raw.map((node, index) => ({
      id: `${snapshotId}:${index}`,
      text: node.text,
      clickable: node.clickable,
      editable: node.editable,
      role: node.role,
      bounds: node.bounds,
      index,
      password: node.password,
      web: node.web,
    }));
    this.stored = { snapshotId, at: this.now(), nodes };
    const screen: MacScreenRead = {
      snapshotId,
      appLabel: reply.result.appLabel ?? this.app,
      packageName: reply.result.packageName ?? (this.app === "Safari" ? "com.apple.Safari" : "com.google.Chrome"),
      nodes: nodes.map(publicNode),
      truncated: reply.result.truncated === true,
    };
    return screen;
  }

  ui_tap(args: { nodeId: string }): { invoked: boolean } {
    const node = this.requireAddressable(args.nodeId);
    if (node.password || isMacosPayWord(node.text) || !node.clickable) {
      throw new MacosAdapterError("protected_action", `protected_action. ${node.text}`);
    }
    this.stored = null;
    const reply = this.exec({ op: "tap", app: this.app, index: node.index, web: node.web, role: node.role, label: node.text });
    if (!reply.ok) throw liveError(reply);
    return { invoked: true };
  }

  ui_type(args: { nodeId: string; text: string }): { typed: boolean } {
    if (args.text.length > 4096 || CONTROL_CHARS.test(args.text)) {
      throw new MacosAdapterError("protected_action", "protected_action. text");
    }
    const node = this.requireAddressable(args.nodeId);
    if (node.password || !node.editable) {
      throw new MacosAdapterError("protected_action", `protected_action. ${node.text}`);
    }
    this.stored = null;
    const reply = this.exec({ op: "type", app: this.app, index: node.index, role: node.role, label: node.text, text: args.text });
    if (!reply.ok) throw liveError(reply);
    return { typed: true };
  }

  private requireAddressable(nodeId: string): StoredNode {
    const current = this.stored;
    if (current === null || this.now() - current.at > this.snapshotTtlMs) {
      this.stored = null;
      throw new MacosAdapterError("stale_screen", "stale_screen. screen_read again");
    }
    const node = current.nodes.find(item => item.id === nodeId);
    if (node === undefined) throw new MacosAdapterError("stale_screen", `stale_screen. ${nodeId}`);
    return node;
  }
}

export function defaultExec(scriptPath: string): LiveMacosExec {
  return command => {
    if (command.op === "open") return openViaAppleScript(command.app, command.url);
    const result = spawnSync("osascript", ["-l", "JavaScript", scriptPath, JSON.stringify(command)], {
      encoding: "utf8",
      timeout: 20_000,
    });
    const stdout = (result.stdout ?? "").trim();
    const stderr = (result.stderr ?? "").trim();
    if (stdout.length > 0) {
      try {
        return JSON.parse(stdout) as LiveMacosReply;
      } catch {
        /* fall through to combined error */
      }
    }
    const message = `${stdout}\n${stderr}`.trim() || `osascript exit ${result.status ?? "?"}`;
    return { ok: false, code: skipCode(message), message };
  };
}

function openViaAppleScript(app: string, url?: string): LiveMacosReply {
  if (app !== "Safari" && app !== "Google Chrome") {
    return { ok: false, code: "app_not_found", message: `app_not_found. ${app}` };
  }
  const location = url === undefined ? null : httpUrl(url);
  if (url !== undefined && location === null) {
    return { ok: false, code: "invalid_request", message: "invalid_request. url" };
  }
  const source = location === null
    ? `tell application "${app}"\nactivate\nreturn name of front window\nend tell`
    : `tell application "${app}"\nactivate\nopen location "${location}"\ndelay 2\nif (count of windows) is 0 then error "no window"\nreturn name of front window\nend tell`;
  const result = spawnSync("osascript", ["-e", source], { encoding: "utf8", timeout: 20_000 });
  if (result.status === 0) return { ok: true, result: { opened: true, app } };
  const message = `${result.stdout ?? ""}\n${result.stderr ?? ""}`.trim();
  return { ok: false, code: skipCode(message), message };
}

function httpUrl(raw: string): string | null {
  try {
    const parsed = new URL(raw);
    if ((parsed.protocol !== "http:" && parsed.protocol !== "https:") || parsed.username || parsed.password) {
      return null;
    }
    return parsed.href;
  } catch {
    return null;
  }
}

export function skipCode(message: string): string {
  if (/assistive access|AXIsProcessTrusted|-25211|손쉬운 사용|not trusted|not authorized|-1743|1002/i.test(message)) {
    return "accessibility";
  }
  if (/app_not_found|can’t get|can't get/i.test(message)) return "app_not_found";
  return "failed";
}

function publicNode(node: StoredNode): MacScreenNode {
  return {
    id: node.id,
    text: node.text,
    clickable: node.clickable,
    editable: node.editable,
    role: node.role,
    bounds: node.bounds,
  };
}

function liveError(reply: LiveMacosErr): MacosAdapterError {
  return new MacosAdapterError(reply.code, reply.message);
}

export function liveAxRequested(env: NodeJS.ProcessEnv = process.env): boolean {
  return env.PPOMI_BODY_LIVE === "1" || env.PPOMI_BODY_AX === "1";
}

const SMOKE_LINK = /more information|추가\s*정보/i;
const SMOKE_PAGE = /example domain/i;

/**
 * Only example.com's "More information" (or 추가 정보) link, and only when the snapshot shows the
 * example.com page. Never an arbitrary link or button: with several browser windows the read may
 * have landed on another tab, and a self-declared `effect: "navigate"` on an unknown control would
 * make the runtime click it.
 */
export function pickLiveAxClickTarget(nodes: readonly MacScreenNode[]): MacScreenNode | undefined {
  if (!nodes.some(node => SMOKE_PAGE.test(node.text))) return undefined;
  return nodes.find(node =>
    node.clickable && !isMacosPayWord(node.text) && SMOKE_LINK.test(node.text));
}
