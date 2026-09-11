import assert from "node:assert/strict";
import { test } from "node:test";
import {
  AndroidAdapterError,
  LiveAndroidNativeTools,
  encodeInputText,
  isAndroidProtectedLabel,
  pickLiveAndroidClickTarget,
  resolveAdbSerial,
  type LiveAndroidCommand,
  type LiveAndroidNode,
  type LiveAndroidReply,
} from "../src/index.ts";

const row: LiveAndroidNode = {
  text: "연결",
  clickable: true,
  editable: false,
  password: false,
  packageName: "com.android.settings",
  resourceId: "com.android.settings:id/row",
  className: "android.widget.LinearLayout",
  bounds: { left: 0, top: 300, right: 1080, bottom: 450 },
};

const field: LiveAndroidNode = {
  text: "",
  contentDescription: "Search",
  clickable: true,
  editable: true,
  password: false,
  packageName: "com.android.settings",
  resourceId: "com.android.settings:id/search",
  className: "android.widget.EditText",
  bounds: { left: 40, top: 200, right: 1040, bottom: 280 },
};

function dump(nodes: readonly LiveAndroidNode[]): LiveAndroidReply {
  return { ok: true, result: { appLabel: "Settings", packageName: "com.android.settings", truncated: false, nodes } };
}

function code(error: unknown): string | undefined {
  return error instanceof AndroidAdapterError ? error.code : undefined;
}

/** Scripted device: the first dump is the read, later dumps come from `fresh` in order. */
function tools(fresh: readonly (readonly LiveAndroidNode[])[]): { tools: LiveAndroidNativeTools; commands: LiveAndroidCommand[] } {
  const commands: LiveAndroidCommand[] = [];
  const dumps = [...fresh];
  const live = new LiveAndroidNativeTools({
    serial: "R3CX",
    exec: command => {
      commands.push(command);
      if (command.op === "dump") return dump(dumps.length > 1 ? dumps.shift()! : dumps[0]!);
      if (command.op === "tap") return { ok: true, result: { invoked: true } };
      if (command.op === "type") return { ok: true, result: { typed: true } };
      return { ok: false, code: "failed", message: command.op };
    },
  });
  return { tools: live, commands };
}

test("gate: the input text argument is single-quoted for the device shell", () => {
  for (const payload of [
    "x; rm -rf /sdcard/Download",
    "a`id`b",
    "a$(reboot)b",
    "a | cat /data/x > /sdcard/y",
    "a && b || c",
    "it's 'quoted'",
    "hello world",
  ]) {
    const encoded = encodeInputText(payload);
    assert.ok(encoded.startsWith("'") && encoded.endsWith("'"), payload);
    // Inside the quotes the only ' is the escape sequence '\'' — nothing can close the quote early.
    assert.equal(encoded.slice(1, -1).replace(/'\\''/g, "").includes("'"), false, payload);
    assert.equal(encoded.includes(" "), false, "spaces travel as %s");
  }
  assert.equal(encodeInputText("hello world"), "'hello%sworld'");
  assert.equal(encodeInputText("it's"), "'it'\\''s'");
});

test("gate: android_type refuses newline and other control characters before any adb call", () => {
  const { tools: live, commands } = tools([[row, field]]);
  const screen = live.android_screen();
  const search = screen.nodes.find(node => node.contentDescription === "Search")!;
  for (const text of ["go\n", "go\r", "a\u0000b", "del\u007f", "c1\u0085"]) {
    assert.equal(code(assertThrows(() => live.android_type({ nodeId: search.id, text }))), "protected_action", JSON.stringify(text));
  }
  assert.equal(commands.some(command => command.op === "tap" || command.op === "type"), false);
});

test("gate: android_click re-reads the screen and taps only the same node at its fresh position", () => {
  const moved: LiveAndroidNode = { ...row, bounds: { left: 0, top: 500, right: 1080, bottom: 650 } };
  const { tools: live, commands } = tools([[row], [moved]]);
  const screen = live.android_screen();
  assert.equal(code(assertThrows(() => live.android_click({ nodeId: screen.nodes[0]!.id }))), "stale_screen", "row moved → stale");
  assert.equal(commands.some(command => command.op === "tap"), false, "no tap after drift");

  const other: LiveAndroidNode = { ...row, text: "초기화", resourceId: "com.android.settings:id/reset" };
  const second = tools([[row], [other]]);
  const shot = second.tools.android_screen();
  assert.equal(code(assertThrows(() => second.tools.android_click({ nodeId: shot.nodes[0]!.id }))), "stale_screen", "different node at the same place → stale");
  assert.equal(second.commands.some(command => command.op === "tap"), false);

  const same = tools([[row], [row]]);
  const again = same.tools.android_screen();
  assert.deepEqual(same.tools.android_click({ nodeId: again.nodes[0]!.id }), { invoked: true });
  assert.deepEqual(same.commands.filter(command => command.op === "dump").length, 2, "read + fresh verify");
  assert.deepEqual(same.commands.find(command => command.op === "tap"), { op: "tap", serial: "R3CX", x: 540, y: 375 });
});

test("gate: android_type taps the fresh field, requires it to hold focus, then types", () => {
  const focused: LiveAndroidNode = { ...field, focused: true, bounds: { left: 40, top: 120, right: 1040, bottom: 200 } };
  const { tools: live, commands } = tools([[row, field], [row, field], [row, focused]]);
  const screen = live.android_screen();
  const search = screen.nodes.find(node => node.contentDescription === "Search")!;
  assert.deepEqual(live.android_type({ nodeId: search.id, text: "wifi" }), { typed: true });
  assert.deepEqual(commands.map(command => command.op), ["dump", "dump", "tap", "dump", "type"]);

  const unfocused = tools([[row, field], [row, field], [row, field]]);
  const shot = unfocused.tools.android_screen();
  const target = shot.nodes.find(node => node.contentDescription === "Search")!;
  assert.equal(code(assertThrows(() => unfocused.tools.android_type({ nodeId: target.id, text: "wifi" }))), "stale_screen");
  assert.equal(unfocused.commands.some(command => command.op === "type"), false, "no typing into an unfocused field");
});

test("gate: destructive and Windows-protected labels are protected_action; safe rows are not", () => {
  for (const label of ["초기화", "공장 초기화", "재설정", "삭제", "제거", "모두 지우기", "Reset", "Factory data reset", "Erase all data", "Uninstall", "Delete", "확인", "Allow", "비밀번호", "Sign in", "결제하기"]) {
    assert.equal(isAndroidProtectedLabel(label), true, label);
  }
  for (const label of ["연결", "Wi-Fi", "블루투스", "알림", "배터리", "디스플레이", "소리", "Connections", "Notifications"]) {
    assert.equal(isAndroidProtectedLabel(label), false, label);
  }
  const reset: LiveAndroidNode = { ...row, text: "일반 관리", contentDescription: "공장 초기화", resourceId: "com.android.settings:id/reset" };
  const { tools: live, commands } = tools([[reset]]);
  const screen = live.android_screen();
  assert.equal(code(assertThrows(() => live.android_click({ nodeId: screen.nodes[0]!.id }))), "protected_action");
  assert.equal(commands.some(command => command.op === "tap"), false);
});

test("gate: the row picker never falls back to the first clickable node", () => {
  assert.equal(
    pickLiveAndroidClickTarget([
      { id: "a", text: "Samsung account", clickable: true, editable: false },
      { id: "b", text: "", contentDescription: "Search", clickable: true, editable: true },
      { id: "c", text: "Reset", clickable: true, editable: false },
    ]),
    undefined,
    "no safe row → no target",
  );
  assert.equal(
    pickLiveAndroidClickTarget([{ id: "n", text: "네트워크 초기화", clickable: true, editable: false }]),
    undefined,
    "a matching row that is also destructive is skipped",
  );
  assert.equal(pickLiveAndroidClickTarget([
    { id: "a", text: "Samsung account", clickable: true, editable: false },
    { id: "b", text: "연결", clickable: true, editable: false },
  ])?.id, "b");
});

test("gate: a live tap needs an explicit device pin; one attached phone is not auto-targeted", () => {
  assert.equal(resolveAdbSerial(["R3CX"]).code, "serial_required");
  assert.equal(resolveAdbSerial(["R3CX"], "R3CX").serial, "R3CX");
  assert.equal(resolveAdbSerial(["R3CX"], "other").code, "no_device");

  const saved = { a: process.env.ANDROID_SERIAL, p: process.env.PPOMI_ANDROID_SERIAL };
  delete process.env.ANDROID_SERIAL;
  delete process.env.PPOMI_ANDROID_SERIAL;
  try {
    const commands: LiveAndroidCommand[] = [];
    const live = new LiveAndroidNativeTools({
      exec: command => {
        commands.push(command);
        if (command.op === "devices") return { ok: true, result: { missing: false, serials: ["R3CX"] } };
        return dump([row]);
      },
    });
    assert.equal(code(assertThrows(() => live.android_screen())), "serial_required");
    assert.equal(commands.length, 0, "nothing is sent to adb without a pin");
  } finally {
    if (saved.a !== undefined) process.env.ANDROID_SERIAL = saved.a;
    if (saved.p !== undefined) process.env.PPOMI_ANDROID_SERIAL = saved.p;
  }
});

function assertThrows(block: () => unknown): unknown {
  try {
    block();
  } catch (error) {
    return error;
  }
  assert.fail("expected an error");
}
