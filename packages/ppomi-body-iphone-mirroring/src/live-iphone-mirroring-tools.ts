import { spawnSync } from "node:child_process";
import { existsSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { AccountCapturePort, isAccountText, maskAccountText } from "./account-capture.ts";
import {
  IphoneMirroringAdapterError,
  type IphoneMirroringTools,
  type PhoneScreenRead,
  type PhoneScreenRow,
} from "./iphone-mirroring-tools.ts";

/** Same pay-word as `MacUI` / `LiveMacosNativeTools`. */
const PAY_WORD = /(?<!바로)(결제|구매|주문|송금|이체|입금|충전|구독|가입)\s*(하기|완료|진행)?\s*$/;
const CONTROL_CHARS = /[\u0000-\u0008\u000A-\u001F\u007F-\u009F]/;
const MIRRORING_BUNDLE = "com.apple.ScreenContinuity";
const AX_APP_NAMES = ["iPhone Mirroring", "iPhone 미러링"] as const;
/** Chrome of the Mac mirroring window — not the iPhone UI. */
const MIRRORING_CHROME =
  /^(home|홈|app switcher|앱 전환기|iphone mirroring|iphone 미러링|연결|재개|일시 정지|사용 중|잠금 해제)$/i;

export interface LiveIphoneAxNode {
  readonly text: string;
  readonly role: string;
  readonly clickable: boolean;
  readonly editable: boolean;
  readonly password: boolean;
  readonly bounds: { left: number; top: number; right: number; bottom: number };
}

export interface LiveIphoneOcrNode {
  readonly text: string;
  readonly x: number;
  readonly y: number;
  readonly w: number;
  readonly h: number;
}

export type LiveIphoneCommand =
  | { readonly op: "trusted" }
  | { readonly op: "activate" }
  | { readonly op: "read_ax" }
  | { readonly op: "read_ocr" }
  | { readonly op: "tap_ax"; readonly index: number; readonly role: string; readonly label: string }
  | { readonly op: "tap_ocr"; readonly x: number; readonly y: number }
  | { readonly op: "type"; readonly text: string }
  | { readonly op: "key"; readonly name: string }
  | { readonly op: "scroll"; readonly dy: number; readonly y?: number };

export interface LiveIphoneOk {
  readonly ok: true;
  readonly result: {
    readonly trusted?: boolean;
    readonly opened?: boolean;
    readonly appLabel?: string;
    readonly source?: "ax" | "ocr";
    readonly nodes?: readonly LiveIphoneAxNode[];
    readonly ocr?: readonly LiveIphoneOcrNode[];
    readonly invoked?: boolean;
    readonly typed?: boolean;
    readonly sent?: boolean;
    readonly scrolled?: boolean;
  };
}

export interface LiveIphoneErr {
  readonly ok: false;
  readonly code: string;
  readonly message: string;
}

export type LiveIphoneReply = LiveIphoneOk | LiveIphoneErr;
export type LiveIphoneExec = (command: LiveIphoneCommand) => LiveIphoneReply;

export interface LiveIphoneMirroringToolsOptions {
  readonly exec?: LiveIphoneExec;
  readonly capture?: AccountCapturePort;
}

interface StoredRow extends PhoneScreenRow {
  readonly raw: string;
  readonly ax?: { index: number; role: string };
  readonly ocr?: { x: number; y: number };
}

/**
 * `IphoneMirroringTools` over the Mac iPhone Mirroring window
 * (`com.apple.ScreenContinuity`). Not on-device iOS AX.
 * Ladder: AX tree → OCR (`phone` CLI). Template / CU are not in this slice.
 */
export class LiveIphoneMirroringTools implements IphoneMirroringTools {
  readonly capture: AccountCapturePort;
  private readonly exec: LiveIphoneExec;
  private stored: { title: string; rows: StoredRow[] } | null = null;

  constructor(options: LiveIphoneMirroringToolsOptions = {}) {
    this.exec = options.exec ?? defaultExec();
    this.capture = options.capture ?? new AccountCapturePort();
  }

  trusted(): boolean {
    const reply = this.exec({ op: "trusted" });
    return reply.ok && reply.result.trusted === true;
  }

  phone_screen(): PhoneScreenRead {
    const screen = this.readLadder();
    this.stored = screen;
    return {
      title: screen.title,
      rows: screen.rows.map(publicRow),
    };
  }

  phone_tap(args: { text?: string; x?: number; y?: number }): { tapped: boolean } {
    if (args.text === undefined) {
      throw new IphoneMirroringAdapterError("text_required", "phone_tap needs observation text, not coordinates");
    }
    const row = this.requireRow(args.text, "tappable");
    if (isPayWord(row.raw) || isAccountText(row.raw)) {
      throw new IphoneMirroringAdapterError("protected_action", `protected_action. ${row.text}`);
    }
    const reply = row.ax !== undefined
      ? this.exec({ op: "tap_ax", index: row.ax.index, role: row.ax.role, label: row.raw })
      : row.ocr !== undefined
        ? this.exec({ op: "tap_ocr", x: row.ocr.x, y: row.ocr.y })
        : { ok: false, code: "stale_screen", message: "stale_screen. no address" } satisfies LiveIphoneErr;
    this.stored = null;
    if (!reply.ok) throw liveError(reply);
    return { tapped: true };
  }

  phone_type(args: { text: string }): { typed: boolean } {
    if (args.text.length > 4096 || CONTROL_CHARS.test(args.text)) {
      throw new IphoneMirroringAdapterError("protected_action", "protected_action. text");
    }
    const screen = this.requireScreen();
    if (!screen.rows.some(row => row.editable)) {
      throw new IphoneMirroringAdapterError("stale_screen", "no editable row on mirrored screen");
    }
    this.stored = null;
    const reply = this.exec({ op: "type", text: args.text });
    if (!reply.ok) throw liveError(reply);
    return { typed: true };
  }

  phone_key(args: { name: string }): { sent: boolean } {
    const reply = this.exec({ op: "key", name: args.name });
    if (!reply.ok) throw liveError(reply);
    return { sent: true };
  }

  phone_scroll(args: { dy: number; y?: number }): { scrolled: boolean } {
    const command: LiveIphoneCommand = args.y === undefined
      ? { op: "scroll", dy: args.dy }
      : { op: "scroll", dy: args.dy, y: args.y };
    const reply = this.exec(command);
    if (!reply.ok) throw liveError(reply);
    return { scrolled: true };
  }

  phone_open(args: { app?: string; title?: string; search?: string }): { opened: boolean; app: string } {
    const requested = args.app ?? args.title;
    const reply = this.exec({ op: "activate" });
    if (!reply.ok) throw liveError(reply);
    this.stored = null;
    const screen = this.readLadder();
    this.stored = screen;
    if (requested !== undefined && requested !== screen.title && !screen.rows.some(row => row.text === requested)) {
      throw new IphoneMirroringAdapterError("app_not_found", `app not on mirrored screen: ${requested}`);
    }
    return { opened: true, app: requested ?? screen.title };
  }

  private readLadder(): { title: string; rows: StoredRow[] } {
    const ax = this.exec({ op: "read_ax" });
    if (ax.ok) {
      const nodes = ax.result.nodes ?? [];
      if (axHasPhoneLabels(nodes)) {
        this.noteCapture(ax.result.appLabel ?? "iPhone Mirroring", nodes.map(node => node.text));
        return fromAx(ax.result.appLabel ?? "iPhone Mirroring", nodes);
      }
    }
    const ocr = this.exec({ op: "read_ocr" });
    if (ocr.ok && (ocr.result.ocr ?? []).length > 0) {
      const nodes = ocr.result.ocr ?? [];
      this.noteCapture(ocr.result.appLabel ?? "iPhone Mirroring", nodes.map(node => node.text));
      return fromOcr(ocr.result.appLabel ?? "iPhone Mirroring", nodes);
    }
    if (ax.ok) {
      const nodes = ax.result.nodes ?? [];
      this.noteCapture(ax.result.appLabel ?? "iPhone Mirroring", nodes.map(node => node.text));
      return fromAx(ax.result.appLabel ?? "iPhone Mirroring", nodes);
    }
    throw liveError(ocr.ok === false ? ocr : ax.ok === false ? ax : { ok: false, code: "failed", message: "no screen" });
  }

  private noteCapture(title: string, texts: readonly string[]): void {
    this.capture.ingest([title, ...texts]);
  }

  private requireScreen(): { title: string; rows: StoredRow[] } {
    if (this.stored !== null) return this.stored;
    return this.readLadder();
  }

  private requireRow(text: string, need: "tappable" | "editable"): StoredRow {
    const screen = this.requireScreen();
    const matches = screen.rows.filter(row => row.text === text);
    if (matches.length === 0) {
      throw new IphoneMirroringAdapterError("target_not_on_screen", `target not on screen: ${text}`);
    }
    const usable = matches.filter(row => (need === "tappable" ? row.tappable : row.editable));
    if (usable.length === 0) {
      throw new IphoneMirroringAdapterError("protected_action", `target not ${need}: ${text}`);
    }
    if (usable.length !== 1) {
      throw new IphoneMirroringAdapterError("ambiguous_target", `ambiguous target: ${text}`);
    }
    return usable[0]!;
  }
}

export function isPayWord(text: string): boolean {
  return PAY_WORD.test(text.trim());
}

export function axHasPhoneLabels(nodes: readonly LiveIphoneAxNode[]): boolean {
  return nodes.some(node => {
    const text = node.text.trim();
    return text.length > 0 && !MIRRORING_CHROME.test(text);
  });
}

export function liveIphoneRequested(env: NodeJS.ProcessEnv = process.env): boolean {
  return env.PPOMI_BODY_LIVE === "1";
}

export function skipCode(message: string): string {
  if (/assistive access|AXIsProcessTrusted|-25211|손쉬운 사용|not trusted|not authorized|-1743|1002/i.test(message)) {
    return "accessibility";
  }
  if (/app_not_found|can’t get|can't get|not running|no window|no mirroring/i.test(message)) return "app_not_found";
  if (/no_phone_cli|phone: not found|ENOENT/i.test(message)) return "no_phone_cli";
  return "failed";
}

export function defaultExec(): LiveIphoneExec {
  const axScript = join(dirname(fileURLToPath(import.meta.url)), "../../ppomi-body-macos/src/ax-jxa.js");
  const phoneCli = findPhoneCli();
  return command => {
    switch (command.op) {
      case "trusted":
        return runAx(axScript, { op: "trusted" });
      case "activate":
        return activateMirroring();
      case "read_ax":
        return readAx(axScript);
      case "read_ocr":
        return readOcr(phoneCli);
      case "tap_ax":
        return tapAx(axScript, command);
      case "tap_ocr":
        return runPhone(phoneCli, ["tap", String(command.x), String(command.y)], "invoked");
      case "type":
        return runPhone(phoneCli, ["type", command.text], "typed");
      case "key":
        return runPhone(phoneCli, ["key", command.name], "sent");
      case "scroll": {
        const args = command.y === undefined
          ? ["scroll", String(command.dy)]
          : ["scroll", String(command.dy), "0.5", String(command.y)];
        return runPhone(phoneCli, args, "scrolled");
      }
      default: {
        const exhaustive: never = command;
        return { ok: false, code: "failed", message: `unknown op ${String(exhaustive)}` };
      }
    }
  };
}

function fromAx(title: string, nodes: readonly LiveIphoneAxNode[]): { title: string; rows: StoredRow[] } {
  return {
    title: maskAccountText(title),
    rows: nodes.map((node, index) => ({
      raw: node.text,
      text: maskAccountText(node.text),
      tappable: node.clickable && !node.password && !isPayWord(node.text) && !isAccountText(node.text),
      editable: node.editable && !node.password,
      ax: { index, role: node.role },
    })),
  };
}

function fromOcr(title: string, nodes: readonly LiveIphoneOcrNode[]): { title: string; rows: StoredRow[] } {
  return {
    title: maskAccountText(title),
    rows: nodes.map(node => ({
      raw: node.text,
      text: maskAccountText(node.text),
      tappable:
        node.text.trim().length > 0
        && !isPayWord(node.text)
        && !isAccountText(node.text)
        && !MIRRORING_CHROME.test(node.text.trim()),
      editable: false,
      ocr: { x: node.x + node.w / 2, y: node.y + node.h / 2 },
    })),
  };
}

function publicRow(row: StoredRow): PhoneScreenRow {
  return { text: row.text, tappable: row.tappable, editable: row.editable };
}

function liveError(reply: LiveIphoneErr): IphoneMirroringAdapterError {
  return new IphoneMirroringAdapterError(reply.code, reply.message);
}

function runAx(scriptPath: string, command: Record<string, unknown>): LiveIphoneReply {
  const result = spawnSync("osascript", ["-l", "JavaScript", scriptPath, JSON.stringify(command)], {
    encoding: "utf8",
    timeout: 20_000,
  });
  return parseSpawn(result);
}

function readAx(scriptPath: string): LiveIphoneReply {
  for (const app of AX_APP_NAMES) {
    const reply = runAx(scriptPath, { op: "read", app });
    if (reply.ok) {
      return {
        ok: true,
        result: {
          appLabel: reply.result.appLabel ?? app,
          source: "ax",
          nodes: reply.result.nodes,
        },
      };
    }
    if (reply.code !== "app_not_found") return reply;
  }
  return { ok: false, code: "app_not_found", message: "iPhone Mirroring AX window not found" };
}

function tapAx(
  scriptPath: string,
  command: { readonly index: number; readonly role: string; readonly label: string },
): LiveIphoneReply {
  for (const app of AX_APP_NAMES) {
    const reply = runAx(scriptPath, {
      op: "tap",
      app,
      index: command.index,
      web: false,
      role: command.role,
      label: command.label,
    });
    if (reply.ok || reply.code !== "app_not_found") return reply;
  }
  return { ok: false, code: "app_not_found", message: "iPhone Mirroring AX window not found" };
}

function activateMirroring(): LiveIphoneReply {
  const result = spawnSync("osascript", ["-e", `tell application id "${MIRRORING_BUNDLE}" to activate`], {
    encoding: "utf8",
    timeout: 20_000,
  });
  if (result.status === 0) return { ok: true, result: { opened: true } };
  const message = `${result.stdout ?? ""}\n${result.stderr ?? ""}`.trim();
  return { ok: false, code: skipCode(message), message };
}

function readOcr(phoneCli: string | null): LiveIphoneReply {
  if (phoneCli === null) return { ok: false, code: "no_phone_cli", message: "phone CLI not built (swiftc phone.swift -o phone)" };
  const tmp = join(process.env.TMPDIR ?? "/tmp", `ppomi-iphone-ocr-${process.pid}.png`);
  const captured = spawnSync(phoneCli, ["capture", tmp], { encoding: "utf8", timeout: 20_000 });
  if (captured.status !== 0) {
    const message = `${captured.stdout ?? ""}\n${captured.stderr ?? ""}`.trim();
    return { ok: false, code: skipCode(message || "capture failed"), message };
  }
  const ocred = spawnSync(phoneCli, ["ocr", tmp], { encoding: "utf8", timeout: 20_000 });
  spawnSync("rm", ["-f", tmp]);
  if (ocred.status !== 0) {
    const message = `${ocred.stdout ?? ""}\n${ocred.stderr ?? ""}`.trim();
    return { ok: false, code: skipCode(message || "ocr failed"), message };
  }
  const ocr: LiveIphoneOcrNode[] = [];
  for (const line of (ocred.stdout ?? "").split("\n")) {
    const trimmed = line.trim();
    if (trimmed.length === 0) continue;
    try {
      const row = JSON.parse(trimmed) as { text?: string; x?: number; y?: number; w?: number; h?: number };
      if (typeof row.text === "string" && row.text.trim().length > 0) {
        ocr.push({
          text: row.text,
          x: Number(row.x) || 0,
          y: Number(row.y) || 0,
          w: Number(row.w) || 0,
          h: Number(row.h) || 0,
        });
      }
    } catch {
      /* phone ocr is one JSON object per line */
    }
  }
  return { ok: true, result: { appLabel: "iPhone Mirroring", source: "ocr", ocr } };
}

function runPhone(phoneCli: string | null, args: readonly string[], flag: "invoked" | "typed" | "sent" | "scrolled"): LiveIphoneReply {
  if (phoneCli === null) return { ok: false, code: "no_phone_cli", message: "phone CLI not built (swiftc phone.swift -o phone)" };
  const result = spawnSync(phoneCli, args, { encoding: "utf8", timeout: 20_000 });
  if (result.status === 0) return { ok: true, result: { [flag]: true } };
  const message = `${result.stdout ?? ""}\n${result.stderr ?? ""}`.trim();
  return { ok: false, code: skipCode(message || `phone ${args[0]} failed`), message };
}

function parseSpawn(result: { status: number | null; stdout: string; stderr: string }): LiveIphoneReply {
  const stdout = (result.stdout ?? "").trim();
  const stderr = (result.stderr ?? "").trim();
  if (stdout.length > 0) {
    try {
      return JSON.parse(stdout) as LiveIphoneReply;
    } catch {
      /* fall through */
    }
  }
  const message = `${stdout}\n${stderr}`.trim() || `osascript exit ${result.status ?? "?"}`;
  return { ok: false, code: skipCode(message), message };
}

function findPhoneCli(): string | null {
  if (process.env.PPOMI_PHONE_CLI !== undefined && existsSync(process.env.PPOMI_PHONE_CLI)) {
    return process.env.PPOMI_PHONE_CLI;
  }
  const root = join(dirname(fileURLToPath(import.meta.url)), "../../..");
  const built = join(root, "phone");
  return existsSync(built) ? built : null;
}
