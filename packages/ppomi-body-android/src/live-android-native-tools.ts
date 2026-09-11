import { spawnSync } from "node:child_process";
import {
  AndroidAdapterError,
  isAndroidOpenPackage,
  type AndroidNativeTools,
  type AndroidScreenNode,
  type AndroidScreenRead,
} from "./android-native-tools.ts";

const SNAPSHOT_TTL_MS = 15_000;
const MAX_NODES = 200;
const SERIAL_OK = /^[A-Za-z0-9._:-]+$/;
const PAY_WORD = /(?<!바로)(결제|구매|주문|송금|이체|입금|충전|구독|가입)\s*(하기|완료|진행)?\s*$/;
const SMOKE_ROW =
  /연결|네트워크|와이파이|wi-?fi|wlan|connections?|network|bluetooth|블루투스|알림|notification|배터리|battery|디스플레이|display|소리/i;

export interface LiveAndroidBounds {
  readonly left: number;
  readonly top: number;
  readonly right: number;
  readonly bottom: number;
}

export interface LiveAndroidNode {
  readonly text: string;
  readonly contentDescription?: string;
  readonly clickable: boolean;
  readonly editable: boolean;
  readonly password: boolean;
  readonly packageName?: string;
  readonly bounds: LiveAndroidBounds;
}

export type LiveAndroidCommand =
  | { readonly op: "devices" }
  | { readonly op: "open"; readonly serial: string; readonly packageName: string }
  | { readonly op: "dump"; readonly serial: string }
  | { readonly op: "tap"; readonly serial: string; readonly x: number; readonly y: number }
  | { readonly op: "type"; readonly serial: string; readonly text: string };

export interface LiveAndroidOk {
  readonly ok: true;
  readonly result: {
    readonly serials?: readonly string[];
    readonly missing?: boolean;
    readonly opened?: boolean;
    readonly packageName?: string;
    readonly appLabel?: string;
    readonly truncated?: boolean;
    readonly nodes?: readonly LiveAndroidNode[];
    readonly invoked?: boolean;
    readonly typed?: boolean;
  };
}

export interface LiveAndroidErr {
  readonly ok: false;
  readonly code: string;
  readonly message: string;
}

export type LiveAndroidReply = LiveAndroidOk | LiveAndroidErr;
export type LiveAndroidExec = (command: LiveAndroidCommand) => LiveAndroidReply;

export interface LiveAndroidNativeToolsOptions {
  readonly serial?: string;
  readonly exec?: LiveAndroidExec;
  readonly now?: () => number;
  readonly snapshotTtlMs?: number;
}

interface StoredNode extends AndroidScreenNode {
  readonly index: number;
  readonly password: boolean;
  readonly bounds: LiveAndroidBounds;
}

/**
 * `AndroidNativeTools` over live `uiautomator dump` + `input tap`.
 * Snapshot ids die after click/type or 15s; payment labels and password fields
 * are `protected_action`. No AccessibilityService APK required.
 */
export class LiveAndroidNativeTools implements AndroidNativeTools {
  private serial: string | undefined;
  private readonly exec: LiveAndroidExec;
  private readonly now: () => number;
  private readonly snapshotTtlMs: number;
  private reads = 0;
  private stored: { snapshotId: string; at: number; nodes: StoredNode[] } | null = null;

  constructor(options: LiveAndroidNativeToolsOptions = {}) {
    if (options.serial !== undefined && !SERIAL_OK.test(options.serial)) {
      throw new AndroidAdapterError("no_device", `invalid serial: ${options.serial}`);
    }
    this.serial = options.serial;
    this.exec = options.exec ?? defaultExec();
    this.now = options.now ?? Date.now;
    this.snapshotTtlMs = options.snapshotTtlMs ?? SNAPSHOT_TTL_MS;
  }

  android_open(args: { packageName: string }): { opened: string } {
    if (!isAndroidOpenPackage(args.packageName)) {
      throw new AndroidAdapterError("app_not_allowed", `android_open refused ${args.packageName}`);
    }
    const reply = this.exec({ op: "open", serial: this.requireSerial(), packageName: args.packageName });
    if (!reply.ok) throw liveError(reply);
    this.stored = null;
    return { opened: args.packageName };
  }

  android_screen(): AndroidScreenRead {
    const reply = this.exec({ op: "dump", serial: this.requireSerial() });
    if (!reply.ok) throw liveError(reply);
    this.reads += 1;
    const snapshotId = `dump-${this.reads}`;
    const raw = reply.result.nodes ?? [];
    const nodes: StoredNode[] = raw.map((node, index) => publicStored(snapshotId, index, node));
    this.stored = { snapshotId, at: this.now(), nodes };
    return {
      snapshotId,
      packageName: reply.result.packageName ?? firstPackage(raw) ?? "com.android.settings",
      appLabel: reply.result.appLabel ?? inferAppLabel(raw, reply.result.packageName),
      nodes: nodes.map(publicNode),
      truncated: reply.result.truncated === true,
    };
  }

  android_click(args: { nodeId: string }): { invoked: boolean } {
    const node = this.requireAddressable(args.nodeId);
    if (node.password || isAndroidPayWord(node.text) || !node.clickable) {
      throw new AndroidAdapterError("protected_action", `protected_action. ${node.text}`);
    }
    const x = Math.round((node.bounds.left + node.bounds.right) / 2);
    const y = Math.round((node.bounds.top + node.bounds.bottom) / 2);
    this.stored = null;
    const reply = this.exec({ op: "tap", serial: this.requireSerial(), x, y });
    if (!reply.ok) throw liveError(reply);
    return { invoked: true };
  }

  android_type(args: { nodeId: string; text: string }): { typed: boolean } {
    if (args.text.length > 4096 || /[\u0000-\u0008\u000B\u000C\u000E-\u001F]/.test(args.text)) {
      throw new AndroidAdapterError("protected_action", "protected_action. text");
    }
    const node = this.requireAddressable(args.nodeId);
    if (node.password || !node.editable) {
      throw new AndroidAdapterError("protected_action", `protected_action. ${node.text}`);
    }
    const x = Math.round((node.bounds.left + node.bounds.right) / 2);
    const y = Math.round((node.bounds.top + node.bounds.bottom) / 2);
    this.stored = null;
    const serial = this.requireSerial();
    const tapped = this.exec({ op: "tap", serial, x, y });
    if (!tapped.ok) throw liveError(tapped);
    const typed = this.exec({ op: "type", serial, text: args.text });
    if (!typed.ok) throw liveError(typed);
    return { typed: true };
  }

  private requireSerial(): string {
    if (this.serial !== undefined) return this.serial;
    const reply = this.exec({ op: "devices" });
    if (!reply.ok) throw liveError(reply);
    if (reply.result.missing === true) {
      throw new AndroidAdapterError("no_adb", "adb not on PATH");
    }
    const pinned = process.env.ANDROID_SERIAL ?? process.env.PPOMI_ANDROID_SERIAL;
    const resolved = resolveAdbSerial(reply.result.serials ?? [], pinned);
    if (resolved.serial === undefined) {
      throw new AndroidAdapterError(resolved.code ?? "no_device", resolved.code ?? "no_device");
    }
    this.serial = resolved.serial;
    return this.serial;
  }

  private requireAddressable(nodeId: string): StoredNode {
    const current = this.stored;
    if (current === null || this.now() - current.at > this.snapshotTtlMs) {
      this.stored = null;
      throw new AndroidAdapterError("stale_screen", "stale_screen. android_screen again");
    }
    const node = current.nodes.find(item => item.id === nodeId);
    if (node === undefined) throw new AndroidAdapterError("stale_screen", `stale_screen. ${nodeId}`);
    return node;
  }
}

export function defaultExec(): LiveAndroidExec {
  return command => {
    switch (command.op) {
      case "devices":
        return devicesReply();
      case "open":
        return openReply(command.serial, command.packageName);
      case "dump":
        return dumpReply(command.serial);
      case "tap":
        return tapReply(command.serial, command.x, command.y);
      case "type":
        return typeReply(command.serial, command.text);
      default: {
        const neverOp: never = command;
        return { ok: false, code: "failed", message: JSON.stringify(neverOp) };
      }
    }
  };
}

export function listAdbDevices(): { missing: boolean; serials: string[] } {
  const reply = devicesReply();
  if (!reply.ok) return { missing: reply.code === "no_adb", serials: [] };
  return { missing: reply.result.missing === true, serials: [...(reply.result.serials ?? [])] };
}

export function parseAdbDevices(text: string): string[] {
  return text
    .split(/\r?\n/)
    .slice(1)
    .map(line => line.trim())
    .filter(line => /\tdevice$/.test(line))
    .map(line => line.split(/\s+/)[0] ?? "")
    .filter(serial => SERIAL_OK.test(serial));
}

export function resolveAdbSerial(
  serials: readonly string[],
  pinned?: string,
): { serial?: string; code?: string } {
  if (pinned !== undefined && serials.includes(pinned)) return { serial: pinned };
  if (serials.length === 0) return { code: "no_device" };
  if (serials.length > 1) return { code: "multiple_devices" };
  return { serial: serials[0] };
}

export function parseUiAutomatorDump(xml: string): LiveAndroidNode[] {
  const nodes: LiveAndroidNode[] = [];
  for (const raw of parseTree(xml)) flatten(raw, nodes);
  return nodes;
}

export function isAndroidPayWord(text: string): boolean {
  return PAY_WORD.test(text.trim());
}

export function liveAndroidRequested(env: NodeJS.ProcessEnv = process.env): boolean {
  return env.PPOMI_BODY_LIVE === "1";
}

export function liveAndroidClickLabel(node: AndroidScreenNode): string {
  const text = node.text.trim();
  if (text.length > 0) return text;
  return node.contentDescription?.trim() ?? "";
}

/** Prefer a Settings row (연결 / Wi-Fi / …). Never a pay word. */
export function pickLiveAndroidClickTarget(nodes: readonly AndroidScreenNode[]): AndroidScreenNode | undefined {
  const clickable = nodes.filter(node => {
    const label = liveAndroidClickLabel(node);
    return node.clickable && label.length > 0 && !isAndroidPayWord(label);
  });
  return clickable.find(node => SMOKE_ROW.test(liveAndroidClickLabel(node))) ?? clickable[0];
}

export function skipCode(message: string): string {
  if (/ENOENT|not found|adb.*PATH/i.test(message)) return "no_adb";
  if (/no devices?|unauthorized|offline|multiple devices/i.test(message)) return "no_device";
  return "failed";
}

function devicesReply(): LiveAndroidReply {
  const result = spawnSync("adb", ["devices"], { encoding: "utf8", timeout: 15_000 });
  if (isMissingAdb(result)) return { ok: true, result: { missing: true, serials: [] } };
  if (result.status !== 0) {
    const message = `${result.stdout ?? ""}\n${result.stderr ?? ""}`.trim();
    return { ok: false, code: skipCode(message), message };
  }
  return { ok: true, result: { missing: false, serials: parseAdbDevices(`${result.stdout ?? ""}`) } };
}

function openReply(serial: string, packageName: string): LiveAndroidReply {
  if (!SERIAL_OK.test(serial)) return { ok: false, code: "no_device", message: `invalid serial: ${serial}` };
  const args = packageName === "com.android.settings"
    ? ["-s", serial, "shell", "am", "start", "-a", "android.settings.SETTINGS"]
    : ["-s", serial, "shell", "monkey", "-p", packageName, "-c", "android.intent.category.LAUNCHER", "1"];
  const result = adb(args);
  if (result.missing) return { ok: false, code: "no_adb", message: "adb not on PATH" };
  if (!result.ok) return { ok: false, code: skipCode(result.text), message: result.text };
  // ponytail: fixed settle after am start; poll dumpsys if Settings is slow to draw
  spawnSync("adb", ["-s", serial, "shell", "sleep", "1.5"], { encoding: "utf8", timeout: 8_000 });
  return { ok: true, result: { opened: true, packageName } };
}

function dumpReply(serial: string): LiveAndroidReply {
  if (!SERIAL_OK.test(serial)) return { ok: false, code: "no_device", message: `invalid serial: ${serial}` };
  const first = adb(["-s", serial, "exec-out", "uiautomator", "dump", "/dev/tty"]);
  if (first.missing) return { ok: false, code: "no_adb", message: "adb not on PATH" };
  let xml = extractHierarchy(first.text);
  if (xml === null) {
    const path = "/sdcard/window_dump.xml";
    adb(["-s", serial, "shell", "uiautomator", "dump", path]);
    const second = adb(["-s", serial, "exec-out", "cat", path]);
    xml = extractHierarchy(second.text);
  }
  if (xml === null) {
    return { ok: false, code: "failed", message: first.text || "uiautomator dump produced no hierarchy" };
  }
  const nodes = parseUiAutomatorDump(xml);
  const truncated = nodes.length > MAX_NODES;
  const kept = truncated ? nodes.slice(0, MAX_NODES) : nodes;
  const packageName = firstPackage(kept) ?? "com.android.settings";
  return {
    ok: true,
    result: {
      packageName,
      appLabel: inferAppLabel(kept, packageName),
      nodes: kept,
      truncated,
    },
  };
}

function tapReply(serial: string, x: number, y: number): LiveAndroidReply {
  if (!SERIAL_OK.test(serial)) return { ok: false, code: "no_device", message: `invalid serial: ${serial}` };
  const result = adb(["-s", serial, "shell", "input", "tap", String(x), String(y)]);
  if (result.missing) return { ok: false, code: "no_adb", message: "adb not on PATH" };
  if (!result.ok) return { ok: false, code: skipCode(result.text), message: result.text };
  return { ok: true, result: { invoked: true } };
}

function typeReply(serial: string, text: string): LiveAndroidReply {
  if (!SERIAL_OK.test(serial)) return { ok: false, code: "no_device", message: `invalid serial: ${serial}` };
  const encoded = text.replace(/ /g, "%s");
  const result = adb(["-s", serial, "shell", "input", "text", encoded]);
  if (result.missing) return { ok: false, code: "no_adb", message: "adb not on PATH" };
  if (!result.ok) return { ok: false, code: skipCode(result.text), message: result.text };
  return { ok: true, result: { typed: true } };
}

function adb(args: readonly string[]): { ok: boolean; text: string; missing: boolean } {
  const result = spawnSync("adb", [...args], { encoding: "utf8", timeout: 20_000, maxBuffer: 8 * 1024 * 1024 });
  const missing = isMissingAdb(result);
  const text = `${result.stdout ?? ""}${result.stderr ?? ""}`.trim();
  return { ok: result.status === 0 && !missing, text, missing };
}

function isMissingAdb(result: { error?: NodeJS.ErrnoException }): boolean {
  return result.error !== undefined && result.error.code === "ENOENT";
}

interface RawNode {
  readonly attrs: Readonly<Record<string, string>>;
  readonly children: RawNode[];
}

function parseTree(xml: string): RawNode[] {
  const root: RawNode[] = [];
  const stack: RawNode[] = [];
  const tag = /<(\/)?node\b([^>]*)(\/)?>/g;
  let match: RegExpExecArray | null;
  while ((match = tag.exec(xml)) !== null) {
    if (match[1] === "/") {
      stack.pop();
      continue;
    }
    const node: RawNode = { attrs: parseAttrs(match[2] ?? ""), children: [] };
    const parent = stack[stack.length - 1];
    if (parent) parent.children.push(node);
    else root.push(node);
    if (match[3] !== "/") stack.push(node);
  }
  return root;
}

function parseAttrs(raw: string): Record<string, string> {
  const attrs: Record<string, string> = {};
  const attr = /([A-Za-z0-9:_-]+)="([^"]*)"/g;
  let match: RegExpExecArray | null;
  while ((match = attr.exec(raw)) !== null) {
    attrs[match[1]!] = decode(match[2] ?? "");
  }
  return attrs;
}

function flatten(raw: RawNode, out: LiveAndroidNode[]): void {
  const clickable = raw.attrs.clickable === "true";
  const password = raw.attrs.password === "true";
  const className = raw.attrs.class ?? "";
  const editable = password || /EditText$/.test(className);
  const ownText = (raw.attrs.text ?? "").trim();
  const ownDesc = (raw.attrs["content-desc"] ?? "").trim();
  const label = ownText || ownDesc ? { text: ownText, desc: ownDesc } : firstLabel(raw);
  const bounds = parseBounds(raw.attrs.bounds ?? "");
  if (bounds !== null && (label.text || label.desc) && (clickable || editable || ownText || ownDesc)) {
    const node: {
      text: string;
      clickable: boolean;
      editable: boolean;
      password: boolean;
      bounds: LiveAndroidBounds;
      contentDescription?: string;
      packageName?: string;
    } = {
      text: label.text,
      clickable,
      editable,
      password,
      bounds,
    };
    if (label.desc.length > 0) node.contentDescription = label.desc;
    if (raw.attrs.package) node.packageName = raw.attrs.package;
    out.push(node);
  }
  for (const child of raw.children) flatten(child, out);
}

function firstLabel(raw: RawNode): { text: string; desc: string } {
  for (const child of raw.children) {
    const text = (child.attrs.text ?? "").trim();
    const desc = (child.attrs["content-desc"] ?? "").trim();
    if (text || desc) return { text, desc };
    const inner = firstLabel(child);
    if (inner.text || inner.desc) return inner;
  }
  return { text: "", desc: "" };
}

function parseBounds(raw: string): LiveAndroidBounds | null {
  const match = /\[(\d+),(\d+)\]\[(\d+),(\d+)\]/.exec(raw);
  if (match === null) return null;
  return {
    left: Number(match[1]),
    top: Number(match[2]),
    right: Number(match[3]),
    bottom: Number(match[4]),
  };
}

function extractHierarchy(text: string): string | null {
  const match = /<hierarchy[\s\S]*<\/hierarchy>/.exec(text);
  return match?.[0] ?? null;
}

function decode(value: string): string {
  return value
    .replace(/&quot;/g, "\"")
    .replace(/&apos;/g, "'")
    .replace(/&lt;/g, "<")
    .replace(/&gt;/g, ">")
    .replace(/&amp;/g, "&");
}

function firstPackage(nodes: readonly LiveAndroidNode[]): string | undefined {
  return nodes.find(node => node.packageName !== undefined)?.packageName;
}

function inferAppLabel(nodes: readonly LiveAndroidNode[], packageName?: string): string {
  const titled = nodes.find(node => /^(Settings|설정)$/.test(node.text.trim()));
  if (titled !== undefined) return titled.text.trim();
  if ((packageName ?? firstPackage(nodes)) === "com.android.settings") return "Settings";
  return packageName ?? "Android";
}

function publicStored(snapshotId: string, index: number, node: LiveAndroidNode): StoredNode {
  const stored: StoredNode = {
    id: `${snapshotId}:${index}`,
    text: node.text,
    clickable: node.clickable,
    editable: node.editable,
    index,
    password: node.password,
    bounds: node.bounds,
  };
  if (node.contentDescription !== undefined) {
    return { ...stored, contentDescription: node.contentDescription };
  }
  return stored;
}

function publicNode(node: StoredNode): AndroidScreenNode {
  const published: {
    id: string;
    text: string;
    clickable: boolean;
    editable: boolean;
    contentDescription?: string;
    password?: boolean;
  } = {
    id: node.id,
    text: node.text,
    clickable: node.clickable,
    editable: node.editable,
  };
  if (node.contentDescription !== undefined) published.contentDescription = node.contentDescription;
  if (node.password === true) published.password = true;
  return published;
}

function liveError(reply: LiveAndroidErr): AndroidAdapterError {
  return new AndroidAdapterError(reply.code, reply.message);
}
