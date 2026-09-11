import assert from "node:assert/strict";
import { test } from "node:test";
import {
  FixedPermissionGate,
  OsSurface,
  Runtime,
} from "../../ppomi-body/src/index.ts";
import {
  AndroidAdapterError,
  AndroidDriver,
  LiveAndroidNativeTools,
  isAndroidPayWord,
  liveAndroidRequested,
  parseAdbDevices,
  parseUiAutomatorDump,
  pickLiveAndroidClickTarget,
  resolveAdbSerial,
  skipCode,
  type LiveAndroidCommand,
  type LiveAndroidExec,
  type LiveAndroidNode,
  type LiveAndroidReply,
} from "../src/index.ts";

const dumpXml = `<?xml version='1.0' encoding='UTF-8' standalone='yes' ?>
<hierarchy rotation="0">
  <node text="" class="android.widget.FrameLayout" package="com.android.settings" clickable="false" password="false" bounds="[0,0][1080,2400]">
    <node text="설정" class="android.widget.TextView" package="com.android.settings" clickable="false" password="false" bounds="[40,80][400,160]"/>
    <node text="" class="android.widget.LinearLayout" package="com.android.settings" clickable="true" password="false" bounds="[0,300][1080,450]">
      <node text="연결" class="android.widget.TextView" package="com.android.settings" clickable="false" password="false" bounds="[48,320][400,430]"/>
    </node>
    <node text="결제하기" class="android.widget.Button" package="com.android.settings" clickable="true" password="false" bounds="[0,500][1080,600]"/>
    <node text="" content-desc="Search" class="android.widget.EditText" package="com.android.settings" clickable="true" password="false" bounds="[40,200][1040,280]"/>
  </node>
</hierarchy>`;

const connection: LiveAndroidNode = {
  text: "연결",
  clickable: true,
  editable: false,
  password: false,
  packageName: "com.android.settings",
  bounds: { left: 0, top: 300, right: 1080, bottom: 450 },
};

function scripted(handler: (command: LiveAndroidCommand) => LiveAndroidReply): LiveAndroidExec {
  return handler;
}

function readReply(nodes: readonly LiveAndroidNode[]): LiveAndroidReply {
  return {
    ok: true,
    result: {
      appLabel: "Settings",
      packageName: "com.android.settings",
      truncated: false,
      nodes,
    },
  };
}

test("adb serials / pay word / skip codes / live flag", () => {
  assert.deepEqual(parseAdbDevices("List of devices attached\nR3CX\tdevice\nemulator-5554\toffline\n"), ["R3CX"]);
  assert.equal(resolveAdbSerial(["a", "b"]).code, "multiple_devices");
  assert.equal(resolveAdbSerial(["a", "b"], "b").serial, "b");
  assert.equal(isAndroidPayWord("결제하기"), true);
  assert.equal(isAndroidPayWord("바로구매"), false);
  assert.equal(skipCode("adb: command not found"), "no_adb");
  assert.equal(liveAndroidRequested({ PPOMI_BODY_LIVE: "1" }), true);
  assert.equal(liveAndroidRequested({ PPOMI_BODY_LIVE: "0" }), false);
});

test("parseUiAutomatorDump lifts Settings row text onto the clickable parent", () => {
  const nodes = parseUiAutomatorDump(dumpXml);
  const row = nodes.find(node => node.text === "연결" && node.clickable);
  assert.ok(row);
  assert.deepEqual(row?.bounds, { left: 0, top: 300, right: 1080, bottom: 450 });
  assert.equal(nodes.some(node => node.text === "결제하기" && node.clickable), true);
  assert.equal(nodes.some(node => node.contentDescription === "Search" && node.editable), true);
});

test("pickLiveAndroidClickTarget prefers 연결 over a pay word", () => {
  const picked = pickLiveAndroidClickTarget([
    { id: "a", text: "설정", clickable: false, editable: false },
    { id: "b", text: "연결", clickable: true, editable: false },
    { id: "c", text: "결제하기", clickable: true, editable: false },
  ]);
  assert.equal(picked?.text, "연결");
  assert.equal(
    pickLiveAndroidClickTarget([{ id: "x", text: "결제하기", clickable: true, editable: false }]),
    undefined,
  );
});

test("pickLiveAndroidClickTarget never falls back to an arbitrary clickable", () => {
  const otherApp = [
    { id: "a", text: "로그아웃", clickable: true, editable: false },
    { id: "b", text: "연결", clickable: true, editable: false },
  ];
  assert.equal(pickLiveAndroidClickTarget(otherApp), undefined, "연결 without Settings/설정 page");
  assert.equal(
    pickLiveAndroidClickTarget([
      { id: "h", text: "설정", clickable: false, editable: false },
      { id: "x", text: "로그아웃", clickable: true, editable: false },
    ]),
    undefined,
    "Settings page without a smoke row",
  );
});

test("LiveAndroidNativeTools: read → tap → stale_screen, pay word refused", () => {
  const commands: LiveAndroidCommand[] = [];
  const pay: LiveAndroidNode = {
    text: "결제하기",
    clickable: true,
    editable: false,
    password: false,
    bounds: { left: 0, top: 500, right: 1080, bottom: 600 },
  };
  const tools = new LiveAndroidNativeTools({
    serial: "R3CX",
    exec: scripted(command => {
      commands.push(command);
      if (command.op === "dump") return readReply([connection, pay]);
      if (command.op === "tap") return { ok: true, result: { invoked: true } };
      return { ok: false, code: "failed", message: JSON.stringify(command) };
    }),
  });

  const screen = tools.android_screen();
  assert.equal(screen.appLabel, "Settings");
  assert.equal(screen.packageName, "com.android.settings");
  assert.equal(screen.nodes[0]?.text, "연결");
  assert.deepEqual(tools.android_click({ nodeId: screen.nodes[0]!.id }), { invoked: true });
  assert.equal(
    commands.some(command => command.op === "tap" && command.x === 540 && command.y === 375),
    true,
  );
  assert.throws(() => tools.android_click({ nodeId: screen.nodes[0]!.id }), error =>
    error instanceof AndroidAdapterError && error.code === "stale_screen");

  const fresh = tools.android_screen();
  assert.throws(() => tools.android_click({ nodeId: fresh.nodes[1]!.id }), error =>
    error instanceof AndroidAdapterError && error.code === "protected_action");
  assert.equal(commands.filter(command => command.op === "tap").length, 1);
});

test("AndroidDriver Runtime 1-step clicks through LiveAndroidNativeTools without a device", async () => {
  const heading: LiveAndroidNode = {
    text: "설정",
    clickable: false,
    editable: false,
    password: false,
    bounds: { left: 40, top: 80, right: 400, bottom: 160 },
  };
  const tools = new LiveAndroidNativeTools({
    serial: "R3CX",
    exec: scripted(command => {
      if (command.op === "dump") return readReply([heading, connection]);
      if (command.op === "tap") return { ok: true, result: { invoked: true } };
      return { ok: false, code: "failed", message: command.op };
    }),
  });
  const preview = tools.android_screen();
  const target = pickLiveAndroidClickTarget(preview.nodes);
  assert.equal(target?.text, "연결");

  const result = await new Runtime(
    new OsSurface(new AndroidDriver(tools)),
    new FixedPermissionGate(["ui.read", "ui.control"]),
  ).run({
    id: "live-uia-fixture",
    steps: [{ id: "uia-click", kind: "click", target: target!.text, effect: "navigate" }],
  });

  assert.equal(result.status, "completed");
  assert.equal(result.stepResults[0]?.driver, "os-android");
  assert.equal(result.stepResults[0]?.status, "ok");
});

test("no_adb reply becomes AndroidAdapterError so the example can SKIP", () => {
  const tools = new LiveAndroidNativeTools({
    serial: "R3CX",
    exec: scripted(() => ({ ok: false, code: "no_adb", message: "adb not on PATH" })),
  });
  assert.throws(() => tools.android_screen(), error =>
    error instanceof AndroidAdapterError && error.code === "no_adb");
});

test("gate: tap uses the live dump frame, not the first-read point after the tree drifts", () => {
  const drifted: LiveAndroidNode = {
    ...connection,
    text: "알림",
    bounds: { left: 0, top: 800, right: 1080, bottom: 950 },
  };
  const commands: LiveAndroidCommand[] = [];
  let dumps = 0;
  const tools = new LiveAndroidNativeTools({
    serial: "R3CX",
    exec: scripted(command => {
      commands.push(command);
      if (command.op === "dump") {
        dumps += 1;
        return readReply([dumps === 1 ? connection : drifted]);
      }
      if (command.op === "tap") return { ok: true, result: { invoked: true } };
      return { ok: false, code: "failed", message: JSON.stringify(command) };
    }),
  });
  const screen = tools.android_screen();
  assert.throws(() => tools.android_click({ nodeId: screen.nodes[0]!.id }), error =>
    error instanceof AndroidAdapterError && error.code === "stale_screen");
  assert.equal(commands.some(command => command.op === "tap"), false);
});

test("gate: ui_type refuses newline before adb input text", () => {
  const field: LiveAndroidNode = {
    text: "",
    contentDescription: "Search",
    clickable: true,
    editable: true,
    password: false,
    bounds: { left: 40, top: 200, right: 1040, bottom: 280 },
  };
  const commands: LiveAndroidCommand[] = [];
  const tools = new LiveAndroidNativeTools({
    serial: "R3CX",
    exec: scripted(command => {
      commands.push(command);
      if (command.op === "dump") return readReply([field]);
      return { ok: true, result: { typed: true } };
    }),
  });
  const screen = tools.android_screen();
  assert.throws(() => tools.android_type({ nodeId: screen.nodes[0]!.id, text: "submit\n" }), error =>
    error instanceof AndroidAdapterError && error.code === "protected_action");
  assert.equal(commands.some(command => command.op === "type" || command.op === "tap"), false);
});
