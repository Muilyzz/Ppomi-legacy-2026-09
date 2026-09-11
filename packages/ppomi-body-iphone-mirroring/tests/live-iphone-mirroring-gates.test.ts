import assert from "node:assert/strict";
import { chmodSync, existsSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { test } from "node:test";
import {
  FixedPermissionGate,
  OsSurface,
  Runtime,
} from "../../ppomi-body/src/index.ts";
import {
  IPHONE_SNAPSHOT_TTL_MS,
  IphoneMirroringAdapterError,
  IphoneMirroringDriver,
  LiveIphoneMirroringTools,
  axHasPhoneLabels,
  defaultExec,
  isProtectedLabel,
  type LiveIphoneAxNode,
  type LiveIphoneCommand,
  type LiveIphoneOcrNode,
  type LiveIphoneReply,
} from "../src/index.ts";

/** Synthetic placeholders only. */
const SYNTHETIC_ACCOUNT = "001234-56-789012";

function ax(text: string, role = "button", clickable = true): LiveIphoneAxNode {
  return { text, role, clickable, editable: false, password: false, bounds: { left: 0, top: 0, right: 40, bottom: 20 } };
}

function ocr(text: string, x: number, y: number, w = 0.2, h = 0.04): LiveIphoneOcrNode {
  return { text, x, y, w, h };
}

function axReply(nodes: readonly LiveIphoneAxNode[]): LiveIphoneReply {
  return { ok: true, result: { appLabel: "iPhone Mirroring", source: "ax", nodes } };
}

function ocrReply(nodes: readonly LiveIphoneOcrNode[]): LiveIphoneReply {
  return { ok: true, result: { appLabel: "iPhone Mirroring", source: "ocr", ocr: nodes } };
}

const chromeHome = ax("Home");
const ACCOUNTS_BOX = ocr("계좌조회", 0.3, 0.28);

/**
 * A mirroring window whose AX is chrome only, so reads go to OCR. `reads` are the
 * successive `read_ocr` answers; the last one repeats.
 */
function ocrScreen(reads: readonly LiveIphoneReply[], now?: () => number): {
  tools: LiveIphoneMirroringTools;
  commands: LiveIphoneCommand[];
} {
  const commands: LiveIphoneCommand[] = [];
  let read = 0;
  const tools = new LiveIphoneMirroringTools({
    ...(now === undefined ? {} : { now }),
    exec: command => {
      commands.push(command);
      switch (command.op) {
        case "read_ax":
          return axReply([chromeHome]);
        case "read_ocr":
          return reads[Math.min(read++, reads.length - 1)]!;
        case "tap_ocr":
        case "key":
        case "scroll":
          return { ok: true, result: { invoked: true, sent: true, scrolled: true } };
        case "trusted":
        case "activate":
        case "tap_ax":
        case "type":
          return { ok: false, code: "failed", message: command.op };
        default: {
          const exhaustive: never = command;
          throw new Error(String(exhaustive));
        }
      }
    },
  });
  return { tools, commands };
}

function code(error: unknown): string {
  return error instanceof IphoneMirroringAdapterError ? error.code : String(error);
}

function ops(commands: readonly LiveIphoneCommand[]): string[] {
  return commands.map(command => command.op);
}

test("OCR tap re-reads right before the click and taps the fresh box, never the read-time one", () => {
  const moved = ocr("계좌조회", 0.31, 0.29);
  const { tools, commands } = ocrScreen([ocrReply([ACCOUNTS_BOX]), ocrReply([moved])]);
  tools.phone_screen();
  assert.deepEqual(tools.phone_tap({ text: "계좌조회" }), { tapped: true });
  assert.deepEqual(ops(commands), ["read_ax", "read_ocr", "read_ocr", "tap_ocr"]);
  const tap = commands[3];
  assert.ok(tap?.op === "tap_ocr");
  assert.ok(Math.abs(tap.x - (0.31 + 0.1)) < 1e-9 && Math.abs(tap.y - (0.29 + 0.02)) < 1e-9);
  assert.notEqual(tap.x, 0.3 + 0.1);
});

test("OCR tap refuses when the re-read shows the target moved, gone, degenerate, outside, ambiguous, or unreadable", () => {
  const cases: { name: string; second: LiveIphoneReply }[] = [
    { name: "moved", second: ocrReply([ocr("계좌조회", 0.3, 0.6)]) },
    { name: "gone", second: ocrReply([ocr("이체내역", 0.3, 0.28)]) },
    { name: "empty", second: ocrReply([]) },
    { name: "degenerate", second: ocrReply([ocr("계좌조회", 0.3, 0.28, 0, 0)]) },
    { name: "outside", second: ocrReply([ocr("계좌조회", 0.3, 0.28, 0.8, 0.04)]) },
    { name: "ambiguous", second: ocrReply([ACCOUNTS_BOX, ocr("계좌조회", 0.32, 0.29)]) },
    { name: "unreadable", second: { ok: false, code: "failed", message: "capture failed" } },
  ];
  for (const item of cases) {
    const { tools, commands } = ocrScreen([ocrReply([ACCOUNTS_BOX]), item.second]);
    tools.phone_screen();
    assert.throws(() => tools.phone_tap({ text: "계좌조회" }), error => code(error) === "stale_screen", item.name);
    assert.equal(commands.some(command => command.op === "tap_ocr"), false, `${item.name}: no click`);
    assert.equal(ops(commands).filter(op => op === "read_ocr").length, 2, `${item.name}: re-read happened`);
  }
});

test("read-time OCR boxes that are degenerate or outside the window are not tappable", () => {
  const { tools, commands } = ocrScreen([
    ocrReply([ocr("zero", 0, 0, 0, 0), ocr("outside", 1.2, 0.5), ocr("negative", -0.1, 0.5), ACCOUNTS_BOX]),
  ]);
  const rows = tools.phone_screen().rows;
  assert.deepEqual(rows.map(row => row.tappable), [false, false, false, true]);
  assert.throws(() => tools.phone_tap({ text: "zero" }), error => code(error) === "protected_action");
  assert.equal(commands.some(command => command.op === "tap_ocr"), false);
});

test("a read older than the snapshot TTL is taken again before acting", () => {
  assert.equal(IPHONE_SNAPSHOT_TTL_MS, 15_000);
  let clock = 0;
  const { tools, commands } = ocrScreen([ocrReply([ACCOUNTS_BOX])], () => clock);
  tools.phone_screen();
  clock = IPHONE_SNAPSHOT_TTL_MS + 1;
  tools.phone_tap({ text: "계좌조회" });
  assert.deepEqual(ops(commands), ["read_ax", "read_ocr", "read_ax", "read_ocr", "read_ocr", "tap_ocr"]);
});

test("exec error text becomes a known code plus one masked line, in the error and in StepResult", async () => {
  const tools = new LiveIphoneMirroringTools({
    exec: command => {
      if (command.op === "read_ax") return axReply([ax("계좌조회")]);
      if (command.op === "tap_ax") {
        return { ok: false, code: "protected_action", message: `protected_action. ${SYNTHETIC_ACCOUNT} 이체\n second line` };
      }
      return { ok: false, code: "failed", message: command.op };
    },
  });
  tools.phone_screen();
  assert.throws(() => tools.phone_tap({ text: "계좌조회" }), error =>
    code(error) === "protected_action" && (error as Error).message === "protected_action. ****9012 이체 second line");

  const result = await new Runtime(
    new OsSurface(new IphoneMirroringDriver(tools)),
    new FixedPermissionGate(["ui.read", "ui.control"]),
  ).run({ id: "p", steps: [{ id: "s", kind: "click", target: "계좌조회", effect: "navigate" }] });
  assert.equal(result.stepResults[0]?.status, "protected");
  assert.equal(JSON.stringify(result).includes("001234"), false);

  const unknown = new LiveIphoneMirroringTools({
    exec: command => {
      if (command.op === "read_ax") return axReply([ax("계좌조회")]);
      return { ok: false, code: "weird_internal_code", message: "x".repeat(500) };
    },
  });
  unknown.phone_screen();
  assert.throws(() => unknown.phone_tap({ text: "계좌조회" }), error =>
    code(error) === "failed" && (error as Error).message.length <= "failed. ".length + 160);
});

test("deny list: withdrawal, credentials, consent and purchase words refuse; OK and navigation rows stay tappable", () => {
  for (const refused of ["출금", "출금계좌", "비밀번호", "간편비밀번호 입력", "OTP", "OTP 번호", "인증번호", "동의", "약관 동의", "Buy", "Apple Pay", "Pay", "Payment", "Purchase", "Transfer", "구매", "결제하기", "이체하기 >", "이체 →", "송금 ›"]) {
    assert.equal(isProtectedLabel(refused), true, refused);
  }
  for (const allowed of ["확인", "계좌조회", "이체내역", "이체한도 조회", "PayPal 안내", "취소"]) {
    assert.equal(isProtectedLabel(allowed), false, allowed);
  }
  const { tools, commands } = ocrScreen([
    ocrReply([ocr("출금", 0.1, 0.1), ocr("비밀번호", 0.1, 0.2), ocr("확인", 0.1, 0.3), ocr("이체하기 >", 0.1, 0.4)]),
  ]);
  const rows = tools.phone_screen().rows;
  assert.deepEqual(rows.map(row => row.tappable), [false, false, true, false]);
  assert.throws(() => tools.phone_tap({ text: "출금" }), error => code(error) === "protected_action");
  assert.equal(commands.some(command => command.op === "tap_ocr"), false);
});

test("phone_key: return / paste / edit / spotlight keys are refused before any exec; navigation keys need a current read", () => {
  const { tools, commands } = ocrScreen([ocrReply([ACCOUNTS_BOX])]);
  for (const refused of ["return", "paste", "selectall", "delete", "spotlight", "space", "Return", "cmd+v", ""]) {
    assert.throws(() => tools.phone_key({ name: refused }), error => code(error) === "protected_action", refused);
  }
  assert.deepEqual(commands, []);
  assert.deepEqual(tools.phone_key({ name: "escape" }), { sent: true });
  assert.deepEqual(ops(commands), ["read_ax", "read_ocr", "key"]);
  assert.deepEqual(commands[2], { op: "key", name: "escape" });
  assert.deepEqual(tools.phone_key({ name: "home" }), { sent: true });
  assert.deepEqual(ops(commands).slice(3), ["read_ax", "read_ocr", "key"]);
});

test("phone_scroll: dy must be a bounded non-zero integer and y inside the window; a current read comes first", () => {
  const { tools, commands } = ocrScreen([ocrReply([ACCOUNTS_BOX])]);
  for (const bad of [{ dy: 0 }, { dy: 1.5 }, { dy: 5000 }, { dy: Number.NaN }, { dy: -300, y: 1.5 }, { dy: -300, y: -0.1 }]) {
    assert.throws(() => tools.phone_scroll(bad), error => code(error) === "invalid_request", JSON.stringify(bad));
  }
  assert.deepEqual(commands, []);
  assert.deepEqual(tools.phone_scroll({ dy: -300, y: 0.5 }), { scrolled: true });
  assert.deepEqual(ops(commands), ["read_ax", "read_ocr", "scroll"]);
  assert.deepEqual(commands[2], { op: "scroll", dy: -300, y: 0.5 });
});

test("AX chrome: the window title, overlays and toolbar are not phone labels, so OCR runs; chrome rows are not tappable", () => {
  for (const chrome of [
    ax("홍길동의 iPhone", "window", false),
    ax("iPhone", "window", false),
    ax("연결이 일시 정지됨", "text", false),
    ax("iPhone 사용 중", "text", false),
    ax("iPhone 잠금 해제", "text", false),
    ax("연결이 중단됨", "text", false),
    ax("다시 시도"),
    ax("재개"),
    ax("App Switcher"),
    ax("앱 전환기"),
    chromeHome,
  ]) {
    assert.equal(axHasPhoneLabels([chrome]), false, chrome.text);
  }
  assert.equal(axHasPhoneLabels([ax("홍길동의 iPhone", "window", false), ax("계좌조회")]), true);

  const chromeOnly = new LiveIphoneMirroringTools({
    exec: command => {
      if (command.op === "read_ax") return axReply([ax("홍길동의 iPhone", "window", false), chromeHome, ax("App Switcher")]);
      if (command.op === "read_ocr") return { ok: false, code: "no_phone_cli", message: "phone CLI not built" };
      return { ok: false, code: "failed", message: command.op };
    },
  });
  const rows = chromeOnly.phone_screen().rows;
  assert.deepEqual(rows.map(row => row.tappable), [false, false, false]);
  assert.deepEqual(chromeOnly.lastRead(), { source: "ax", phoneUi: false });
  assert.throws(() => chromeOnly.phone_tap({ text: "Home" }), error => code(error) === "protected_action");

  const { tools } = ocrScreen([ocrReply([ACCOUNTS_BOX])]);
  tools.phone_screen();
  assert.deepEqual(tools.lastRead(), { source: "ocr", phoneUi: true });
});

test("OCR rows split over two boxes on one line are masked together and captured once", () => {
  const { tools } = ocrScreen([
    ocrReply([
      ocr("계좌번호", 0.05, 0.20, 0.15),
      ocr("001234-56", 0.25, 0.20, 0.18),
      ocr("789012", 0.45, 0.20, 0.12),
      ocr("잔액 1,234,567원", 0.05, 0.30, 0.4),
    ]),
  ]);
  const screen = tools.phone_screen();
  assert.deepEqual(screen.rows.map(row => row.text), ["계좌번호", "****", "****9012", "잔액 1,234,567원"]);
  assert.equal(JSON.stringify(screen).includes("789012"), false);
  assert.deepEqual(tools.capture.peekMasked(), { masked: "****9012", last4: "9012" });
});

test("readOcr captures with capture-private into a fresh private temp dir that is removed on every path", { skip: process.platform === "win32" }, () => {
  const dir = mkdtempSync(join(tmpdir(), "ppomi-fake-phone-"));
  const cli = join(dir, "phone");
  const log = join(dir, "calls.log");
  writeFileSync(cli, [
    "#!/bin/sh",
    'printf "%s %s\\n" "$1" "$2" >> "$FAKE_PHONE_LOG"',
    'case "$1" in',
    "  capture-private)",
    '    if [ -n "$FAKE_PHONE_FAIL_CAPTURE" ]; then printf x > "$2"; echo "mirroring window stayed tiny" >&2; exit 1; fi',
    '    printf PNG > "$2"; exit 0;;',
    "  ocr)",
    `    printf '{"x":0.1,"y":0.2,"w":0.3,"h":0.04,"conf":0.9,"text":"계좌조회"}\\n'; exit 0;;`,
    "  *) exit 1;;",
    "esac",
    "",
  ].join("\n"));
  chmodSync(cli, 0o755);
  const previous = { cli: process.env.PPOMI_PHONE_CLI, log: process.env.FAKE_PHONE_LOG, fail: process.env.FAKE_PHONE_FAIL_CAPTURE };
  process.env.PPOMI_PHONE_CLI = cli;
  process.env.FAKE_PHONE_LOG = log;
  delete process.env.FAKE_PHONE_FAIL_CAPTURE;
  try {
    const exec = defaultExec();
    const ok = exec({ op: "read_ocr" });
    assert.ok(ok.ok && ok.result.ocr?.[0]?.text === "계좌조회");
    const calls = readFileSync(log, "utf8").trim().split("\n");
    assert.equal(calls.length, 2);
    const [verb, image] = calls[0]!.split(" ") as [string, string];
    assert.equal(verb, "capture-private");
    assert.ok(dirname(image).startsWith(join(tmpdir(), "ppomi-iphone-ocr-")), image);
    assert.notEqual(image, join(process.env.TMPDIR ?? "/tmp", `ppomi-iphone-ocr-${process.pid}.png`));
    assert.equal(existsSync(dirname(image)), false, "temp dir removed after success");

    process.env.FAKE_PHONE_FAIL_CAPTURE = "1";
    const failed = defaultExec()({ op: "read_ocr" });
    assert.ok(!failed.ok && failed.code === "failed");
    const failedImage = readFileSync(log, "utf8").trim().split("\n")[2]!.split(" ")[1]!;
    assert.equal(existsSync(dirname(failedImage)), false, "temp dir removed after a failed capture");
  } finally {
    for (const [key, value] of [["PPOMI_PHONE_CLI", previous.cli], ["FAKE_PHONE_LOG", previous.log], ["FAKE_PHONE_FAIL_CAPTURE", previous.fail]] as const) {
      if (value === undefined) delete process.env[key];
      else process.env[key] = value;
    }
    rmSync(dir, { recursive: true, force: true });
  }
});
