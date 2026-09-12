import { spawnSync } from "node:child_process";
import { existsSync, mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { AccountCapturePort, isAccountText, maskAccountRows, maskAccountText } from "./account-capture.ts";
import {
  IphoneMirroringAdapterError,
  type IphoneMirroringTools,
  type PhoneScreenRead,
  type PhoneScreenRow,
} from "./iphone-mirroring-tools.ts";

/** Same pay-word as `MacUI` / `LiveMacosNativeTools`, tested after OCR tails (` >`, ` →`, `›`) are stripped. */
const PAY_WORD = /(?<!바로)(결제|구매|주문|송금|이체|입금|충전|구독|가입)\s*(하기|완료|진행)?\s*$/;
const LABEL_TAIL = /[\s>›»→⟩＞:：·・…]+$/u;
/**
 * Anywhere in a label: withdrawal, credential prompts, consent, English purchase words.
 * `확인` is deliberately not here: it would block every OK button.
 */
const PROTECTED_LABEL = /출금|비밀번호|인증번호|\bOTP\b|동의|\bbuy\b|\bpurchase\b|\bpay(?:ment)?\b|\btransfer\b|\bsubscribe\b/i;
const CONTROL_CHARS = /[\u0000-\u0008\u000A-\u001F\u007F-\u009F]/;
const MIRRORING_BUNDLE = "com.apple.ScreenContinuity";
const AX_APP_NAMES = ["iPhone Mirroring", "iPhone 미러링"] as const;
/** Chrome of the Mac mirroring window as OCR reads it — not the iPhone UI. */
const MIRRORING_CHROME =
  /^(home|홈|app switcher|앱 전환기|iphone mirroring|iphone 미러링|연결|재개|일시 정지|사용 중|잠금 해제)$/i;
/**
 * AX text of the Mac window itself: its title (the device name), the toolbar, and the
 * connect / pause / in-use overlays. The phone UI is a video stream and never appears here.
 */
const AX_CHROME = /iphone|mirroring|미러링|^home$|^홈$|app switcher|앱 전환기|연결|재개|일시 정지|사용 중|잠금|중단|다시 시도|계속/i;
const AX_CHROME_ROLES = new Set(["window", "application"]);
/** Navigation keys only. `return` submits, `paste` sends the Mac clipboard, `selectall` / `delete` edit, `spotlight` opens search. */
const KEY_ALLOW = new Set(["escape", "down", "pagedown", "home", "switcher"]);
const SCROLL_MAX = 2000;
/** Normalised window units: how far an OCR box may drift between the read and the tap re-read. */
const OCR_DRIFT = 0.02;
/** Same as `MACOS_SNAPSHOT_TTL_MS`: a read older than this is taken again before acting. */
export const IPHONE_SNAPSHOT_TTL_MS = 15_000;

export interface LiveIphoneAxNode {
  readonly text: string;
  readonly role: string;
  readonly clickable: boolean;
  readonly editable: boolean;
  readonly password: boolean;
  readonly bounds: { left: number; top: number; right: number; bottom: number };
}

/** Top-left origin, 0..1 of the mirroring window (`phone ocr`). */
export interface LiveIphoneOcrNode {
  readonly text: string;
  readonly x: number;
  readonly y: number;
  readonly w: number;
  readonly h: number;
}

/**
 * `tap_ocr` carries the centre of the box found by the re-read done immediately
 * before it, never the read-time coordinates.
 */
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
  readonly now?: () => number;
  readonly snapshotTtlMs?: number;
}

export type LiveIphoneReadSource = "ax" | "ocr";

/** Where the last `phone_screen` came from and whether it showed phone UI rather than Mac chrome. */
export interface LiveIphoneLastRead {
  readonly source: LiveIphoneReadSource;
  readonly phoneUi: boolean;
}

interface OcrBox {
  readonly x: number;
  readonly y: number;
  readonly w: number;
  readonly h: number;
}

interface StoredRow extends PhoneScreenRow {
  readonly raw: string;
  readonly ax?: { index: number; role: string };
  readonly ocr?: OcrBox;
}

interface StoredScreen extends LiveIphoneLastRead {
  readonly title: string;
  readonly rows: StoredRow[];
  readonly at: number;
}

/**
 * `IphoneMirroringTools` over the Mac iPhone Mirroring window
 * (`com.apple.ScreenContinuity`). Not on-device iOS AX.
 * Ladder: AX tree → OCR (`phone` CLI). Template / CU are not in this slice.
 */
export class LiveIphoneMirroringTools implements IphoneMirroringTools {
  readonly capture: AccountCapturePort;
  private readonly exec: LiveIphoneExec;
  private readonly now: () => number;
  private readonly snapshotTtlMs: number;
  private stored: StoredScreen | null = null;
  private last: LiveIphoneLastRead | null = null;

  constructor(options: LiveIphoneMirroringToolsOptions = {}) {
    this.exec = options.exec ?? defaultExec();
    this.capture = options.capture ?? new AccountCapturePort();
    this.now = options.now ?? Date.now;
    this.snapshotTtlMs = options.snapshotTtlMs ?? IPHONE_SNAPSHOT_TTL_MS;
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

  lastRead(): LiveIphoneLastRead | null {
    return this.last;
  }

  phone_tap(args: { text?: string; x?: number; y?: number }): { tapped: boolean } {
    if (args.text === undefined) {
      throw new IphoneMirroringAdapterError("text_required", "phone_tap needs observation text, not coordinates");
    }
    const row = this.requireRow(args.text, "tappable");
    if (isProtectedLabel(row.raw) || isAccountText(row.raw)) {
      throw new IphoneMirroringAdapterError("protected_action", `protected_action. ${row.text}`);
    }
    this.stored = null;
    let reply: LiveIphoneReply;
    if (row.ax !== undefined) {
      reply = this.exec({ op: "tap_ax", index: row.ax.index, role: row.ax.role, label: row.raw });
    } else if (row.ocr !== undefined) {
      const live = this.reverifyOcrRow(row.raw, row.ocr);
      reply = this.exec({ op: "tap_ocr", x: live.x, y: live.y });
    } else {
      reply = { ok: false, code: "stale_screen", message: "no address" };
    }
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
    const name = args.name.trim().toLowerCase();
    if (!KEY_ALLOW.has(name)) {
      throw new IphoneMirroringAdapterError("protected_action", `protected_action. key ${name.replace(/[^a-z0-9+]/g, "")}`);
    }
    this.requireScreen();
    this.stored = null;
    const reply = this.exec({ op: "key", name });
    if (!reply.ok) throw liveError(reply);
    return { sent: true };
  }

  phone_scroll(args: { dy: number; y?: number }): { scrolled: boolean } {
    if (!Number.isInteger(args.dy) || args.dy === 0 || Math.abs(args.dy) > SCROLL_MAX) {
      throw new IphoneMirroringAdapterError("invalid_request", `invalid_request. dy must be a non-zero integer within ±${SCROLL_MAX}`);
    }
    if (args.y !== undefined && !(Number.isFinite(args.y) && args.y >= 0 && args.y <= 1)) {
      throw new IphoneMirroringAdapterError("invalid_request", "invalid_request. y must be within the window (0..1)");
    }
    this.requireScreen();
    this.stored = null;
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

  private readLadder(): StoredScreen {
    const ax = this.exec({ op: "read_ax" });
    if (ax.ok) {
      const nodes = ax.result.nodes ?? [];
      if (axHasPhoneLabels(nodes)) {
        return this.remember(fromAx(ax.result.appLabel ?? "iPhone Mirroring", nodes), "ax", true);
      }
    }
    const ocr = this.exec({ op: "read_ocr" });
    if (ocr.ok && (ocr.result.ocr ?? []).length > 0) {
      return this.remember(fromOcr(ocr.result.appLabel ?? "iPhone Mirroring", ocr.result.ocr ?? []), "ocr", true);
    }
    if (ax.ok) {
      return this.remember(fromAx(ax.result.appLabel ?? "iPhone Mirroring", ax.result.nodes ?? []), "ax", false);
    }
    throw liveError(ocr.ok === false ? ocr : ax.ok === false ? ax : { ok: false, code: "failed", message: "no screen" });
  }

  private remember(read: ScreenRead, source: LiveIphoneReadSource, phoneUi: boolean): StoredScreen {
    this.capture.ingest([read.title, ...read.lines]);
    this.last = { source, phoneUi };
    return { title: read.title, rows: read.rows, source, phoneUi, at: this.now() };
  }

  /**
   * Immediately before an OCR tap: capture + OCR again and accept only the one box
   * with the same text that still overlaps the box the gate checked, inside the
   * window and with a real size. Anything else is `stale_screen`; read-time
   * coordinates are never clicked.
   */
  private reverifyOcrRow(raw: string, checked: OcrBox): { x: number; y: number } {
    const fresh = this.exec({ op: "read_ocr" });
    if (!fresh.ok) {
      throw new IphoneMirroringAdapterError("stale_screen", `stale_screen. re-read failed (${publicCode(fresh.code)})`);
    }
    const wanted = compactLabel(raw);
    const candidates = (fresh.result.ocr ?? []).filter(node =>
      compactLabel(node.text) === wanted && boxesOverlap(checked, node));
    if (candidates.length === 0) {
      throw new IphoneMirroringAdapterError("stale_screen", "stale_screen. target moved or gone on re-read");
    }
    if (candidates.length > 1) {
      throw new IphoneMirroringAdapterError("stale_screen", "stale_screen. target ambiguous on re-read");
    }
    const box = candidates[0]!;
    if (!(box.w > 0 && box.h > 0)) {
      throw new IphoneMirroringAdapterError("stale_screen", "stale_screen. degenerate frame on re-read");
    }
    if (!insideWindow(box)) {
      throw new IphoneMirroringAdapterError("stale_screen", "stale_screen. target outside the mirroring window");
    }
    return { x: box.x + box.w / 2, y: box.y + box.h / 2 };
  }

  private requireScreen(): StoredScreen {
    const current = this.stored;
    if (current !== null && this.now() - current.at <= this.snapshotTtlMs) return current;
    this.stored = null;
    const screen = this.readLadder();
    this.stored = screen;
    return screen;
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
  return PAY_WORD.test(text.trim().replace(LABEL_TAIL, ""));
}

/** Pay words at the end of the label plus the words that are protected anywhere in it. */
export function isProtectedLabel(text: string): boolean {
  return isPayWord(text) || PROTECTED_LABEL.test(text);
}

/** The Mac window's own AX text (title, toolbar, overlays); never a phone UI label. */
export function isAxChrome(node: Pick<LiveIphoneAxNode, "text" | "role">): boolean {
  const text = node.text.trim();
  return text.length === 0 || AX_CHROME_ROLES.has(node.role) || AX_CHROME.test(text) || MIRRORING_CHROME.test(text);
}

export function axHasPhoneLabels(nodes: readonly LiveIphoneAxNode[]): boolean {
  return nodes.some(node => !isAxChrome(node));
}

export function liveIphoneRequested(env: NodeJS.ProcessEnv = process.env): boolean {
  return env.PPOMI_BODY_LIVE === "1";
}

export function skipCode(message: string): string {
  if (/assistive access|AXIsProcessTrusted|-25211|손쉬운 사용|not trusted|not authorized|-1743|1002/i.test(message)) {
    return "accessibility";
  }
  if (/app_not_found|can’t get|can't get|not running|no window|no mirroring/i.test(message)) return "app_not_found";
  if (/no_phone_cli|phone CLI|phone: not found|ENOENT/i.test(message)) return "no_phone_cli";
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

interface ScreenRead {
  readonly title: string;
  readonly rows: StoredRow[];
  /** Raw texts as the capture port should see them (OCR: one string per visual line). */
  readonly lines: readonly string[];
}

function fromAx(title: string, nodes: readonly LiveIphoneAxNode[]): ScreenRead {
  return {
    title: maskAccountText(title),
    rows: nodes.map((node, index) => ({
      raw: node.text,
      text: maskAccountText(node.text),
      tappable: node.clickable
        && !node.password
        && !isProtectedLabel(node.text)
        && !isAccountText(node.text)
        && !isAxChrome(node),
      editable: node.editable && !node.password,
      ax: { index, role: node.role },
    })),
    lines: nodes.map(node => node.text),
  };
}

/**
 * OCR rows keep their node order; masking runs per visual line so an account split
 * over two boxes is still masked, and the capture port sees the joined line.
 */
function fromOcr(title: string, nodes: readonly LiveIphoneOcrNode[]): ScreenRead {
  const lines = groupLines(nodes);
  const masked: string[] = new Array<string>(nodes.length);
  for (const line of lines) {
    const texts = maskAccountRows(line.map(index => nodes[index]!.text));
    line.forEach((index, order) => {
      masked[index] = texts[order]!;
    });
  }
  return {
    title: maskAccountText(title),
    rows: nodes.map((node, index) => ({
      raw: node.text,
      text: masked[index] ?? maskAccountText(node.text),
      tappable:
        node.text.trim().length > 0
        && !isProtectedLabel(node.text)
        && !isAccountText(node.text)
        && !MIRRORING_CHROME.test(node.text.trim())
        && node.w > 0
        && node.h > 0
        && insideWindow(node),
      editable: false,
      ocr: { x: node.x, y: node.y, w: node.w, h: node.h },
    })),
    lines: lines.map(line => line.map(index => nodes[index]!.text).join(" ")),
  };
}

/** Indexes of `nodes` grouped into visual lines (top to bottom), each sorted left to right. */
function groupLines(nodes: readonly LiveIphoneOcrNode[]): number[][] {
  const order = nodes.map((node, index) => ({ index, cy: node.y + node.h / 2, h: node.h, x: node.x }))
    .sort((a, b) => a.cy - b.cy);
  const lines: { cy: number; h: number; members: { index: number; x: number }[] }[] = [];
  for (const item of order) {
    const line = lines[lines.length - 1];
    if (line !== undefined && Math.abs(item.cy - line.cy) <= 0.6 * Math.max(item.h, line.h, 0.01)) {
      line.members.push({ index: item.index, x: item.x });
    } else {
      lines.push({ cy: item.cy, h: item.h, members: [{ index: item.index, x: item.x }] });
    }
  }
  return lines.map(line => line.members.sort((a, b) => a.x - b.x).map(member => member.index));
}

function compactLabel(text: string): string {
  return text.replace(/\s+/g, "");
}

function boxesOverlap(checked: OcrBox, live: OcrBox): boolean {
  return live.x < checked.x + checked.w + OCR_DRIFT
    && checked.x - OCR_DRIFT < live.x + live.w
    && live.y < checked.y + checked.h + OCR_DRIFT
    && checked.y - OCR_DRIFT < live.y + live.h;
}

function insideWindow(box: OcrBox): boolean {
  return Number.isFinite(box.x) && Number.isFinite(box.y) && Number.isFinite(box.w) && Number.isFinite(box.h)
    && box.x >= 0 && box.y >= 0 && box.x + box.w <= 1 && box.y + box.h <= 1;
}

function publicRow(row: StoredRow): PhoneScreenRow {
  return { text: row.text, tappable: row.tappable, editable: row.editable };
}

const PUBLIC_CODES = new Set([
  "accessibility",
  "app_not_found",
  "stale_screen",
  "protected_action",
  "no_phone_cli",
  "invalid_request",
  "failed",
]);

function publicCode(code: string): string {
  return PUBLIC_CODES.has(code) ? code : "failed";
}

/**
 * Exec replies become a known code plus one masked, bounded line. JXA's
 * `protected_action. <live label>` and `phone` stderr never carry raw screen text
 * into a `StepResult`.
 */
function liveError(reply: LiveIphoneErr): IphoneMirroringAdapterError {
  const code = publicCode(reply.code);
  const detail = reply.message.replace(/^[a-z_]+\.\s*/, "").replace(/\s+/g, " ").trim();
  return new IphoneMirroringAdapterError(code, `${code}. ${maskAccountText(detail).slice(0, 160)}`);
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
      const nodes = reply.result.nodes ?? [];
      return {
        ok: true,
        result: {
          appLabel: reply.result.appLabel ?? app,
          source: "ax",
          nodes,
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

/**
 * The capture is a full screenshot of the mirrored (bank) screen: `capture-private`
 * (umask 077 + chmod 600) into a fresh `mkdtemp` directory, removed in `finally` on
 * every path, including a failed capture.
 */
function readOcr(phoneCli: string | null): LiveIphoneReply {
  if (phoneCli === null) return { ok: false, code: "no_phone_cli", message: "phone CLI not built (swiftc phone.swift -o phone)" };
  let dir: string;
  try {
    dir = mkdtempSync(join(tmpdir(), "ppomi-iphone-ocr-"));
  } catch (error) {
    return { ok: false, code: "failed", message: `temp dir: ${error instanceof Error ? error.message : String(error)}` };
  }
  const image = join(dir, "screen.png");
  try {
    const captured = spawnSync(phoneCli, ["capture-private", image], { encoding: "utf8", timeout: 20_000 });
    if (captured.status !== 0) {
      const message = `${captured.stdout ?? ""}\n${captured.stderr ?? ""}`.trim();
      return { ok: false, code: skipCode(message || "capture failed"), message };
    }
    const ocred = spawnSync(phoneCli, ["ocr", image], { encoding: "utf8", timeout: 20_000 });
    if (ocred.status !== 0) {
      const message = `${ocred.stdout ?? ""}\n${ocred.stderr ?? ""}`.trim();
      return { ok: false, code: skipCode(message || "ocr failed"), message };
    }
    return { ok: true, result: { appLabel: "iPhone Mirroring", source: "ocr", ocr: parseOcrLines(ocred.stdout ?? "") } };
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
}

function parseOcrLines(stdout: string): LiveIphoneOcrNode[] {
  const ocr: LiveIphoneOcrNode[] = [];
  for (const line of stdout.split("\n")) {
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
  return ocr;
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
