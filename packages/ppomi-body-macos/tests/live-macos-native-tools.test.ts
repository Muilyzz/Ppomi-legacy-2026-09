import assert from "node:assert/strict";
import { test } from "node:test";
import {
  FixedPermissionGate,
  OsSurface,
  Runtime,
} from "../../ppomi-body/src/index.ts";
import {
  LiveMacosNativeTools,
  MacosAdapterError,
  MacosDriver,
  isMacosPayWord,
  liveAxRequested,
  macosBrowserApp,
  pickLiveAxClickTarget,
  skipCode,
  type LiveAxNode,
  type LiveMacosCommand,
  type LiveMacosExec,
  type LiveMacosReply,
} from "../src/index.ts";

const moreInfo: LiveAxNode = {
  text: "More information...",
  role: "link",
  clickable: true,
  editable: false,
  password: false,
  web: true,
  bounds: { left: 20, top: 80, right: 180, bottom: 104 },
};

const heading: LiveAxNode = {
  text: "Example Domain",
  role: "text",
  clickable: false,
  editable: false,
  password: false,
  web: true,
  bounds: { left: 0, top: 0, right: 800, bottom: 40 },
};

const pay: LiveAxNode = {
  text: "결제하기",
  role: "button",
  clickable: true,
  editable: false,
  password: false,
  web: false,
  bounds: { left: 20, top: 200, right: 120, bottom: 232 },
};

function scripted(handler: (command: LiveMacosCommand) => LiveMacosReply): LiveMacosExec {
  return handler;
}

function readReply(nodes: readonly LiveAxNode[]): LiveMacosReply {
  return {
    ok: true,
    result: {
      appLabel: "Safari",
      packageName: "com.apple.Safari",
      truncated: false,
      nodes,
    },
  };
}

test("macosBrowserApp / pay word / skip codes match MacUI.swift", () => {
  assert.equal(macosBrowserApp("safari"), "Safari");
  assert.equal(macosBrowserApp("com.google.Chrome"), "Google Chrome");
  assert.equal(macosBrowserApp("Notes"), null);
  assert.equal(isMacosPayWord("결제하기"), true);
  assert.equal(isMacosPayWord("구매하기"), true);
  assert.equal(isMacosPayWord("바로구매"), false);
  assert.equal(isMacosPayWord("확인"), false);
  assert.equal(skipCode("osascript is not allowed assistive access. (-25211)"), "accessibility");
  assert.equal(skipCode("not authorized to send Apple events (-1743)"), "accessibility");
  assert.equal(liveAxRequested({ PPOMI_BODY_AX: "1" }), true);
  assert.equal(liveAxRequested({ PPOMI_BODY_LIVE: "0" }), false);
});

test("pickLiveAxClickTarget prefers More information over chrome buttons", () => {
  const picked = pickLiveAxClickTarget([
    { id: "a", text: "File", clickable: true, editable: false, role: "menuitem" },
    { id: "b", text: "Example Domain", clickable: false, editable: false, role: "text" },
    { id: "c", text: "More information...", clickable: true, editable: false, role: "link" },
    { id: "d", text: "결제하기", clickable: true, editable: false, role: "button" },
  ]);
  assert.equal(picked?.text, "More information...");
  assert.equal(
    pickLiveAxClickTarget([{ id: "x", text: "결제하기", clickable: true, editable: false, role: "button" }]),
    undefined,
  );
});

test("LiveMacosNativeTools: read → tap → stale_screen, pay word refused", () => {
  const commands: LiveMacosCommand[] = [];
  const tools = new LiveMacosNativeTools({
    app: "Safari",
    exec: scripted(command => {
      commands.push(command);
      if (command.op === "trusted") return { ok: true, result: { trusted: true } };
      if (command.op === "read") return readReply([heading, moreInfo, pay]);
      if (command.op === "tap") return { ok: true, result: { invoked: true } };
      return { ok: false, code: "failed", message: JSON.stringify(command) };
    }),
  });

  assert.equal(tools.trusted(), true);
  const screen = tools.screen_read();
  assert.equal(screen.appLabel, "Safari");
  assert.equal(screen.packageName, "com.apple.Safari");
  assert.equal(screen.nodes[1]?.text, "More information...");
  assert.deepEqual(tools.ui_tap({ nodeId: screen.nodes[1]!.id }), { invoked: true });
  assert.equal(commands.some(command => command.op === "tap" && command.index === 1 && command.web === true), true);
  assert.throws(() => tools.ui_tap({ nodeId: screen.nodes[1]!.id }), error =>
    error instanceof MacosAdapterError && error.code === "stale_screen");

  const fresh = tools.screen_read();
  assert.throws(() => tools.ui_tap({ nodeId: fresh.nodes[2]!.id }), error =>
    error instanceof MacosAdapterError && error.code === "protected_action");
  assert.equal(commands.filter(command => command.op === "tap").length, 1);
});

test("MacosDriver Runtime 1-step clicks through LiveMacosNativeTools without hardware", async () => {
  const tools = new LiveMacosNativeTools({
    app: "safari",
    exec: scripted(command => {
      if (command.op === "read") return readReply([heading, moreInfo]);
      if (command.op === "tap") return { ok: true, result: { invoked: true } };
      return { ok: false, code: "failed", message: command.op };
    }),
  });
  const preview = tools.screen_read();
  const target = pickLiveAxClickTarget(preview.nodes);
  assert.equal(target?.text, "More information...");

  const result = await new Runtime(
    new OsSurface(new MacosDriver(tools)),
    new FixedPermissionGate(["ui.read", "ui.control"]),
  ).run({
    id: "live-ax-fixture",
    steps: [{ id: "ax-click", kind: "click", target: target!.text, effect: "navigate" }],
  });

  assert.equal(result.status, "completed");
  assert.equal(result.stepResults[0]?.driver, "os-macos");
  assert.equal(result.stepResults[0]?.status, "ok");
});

test("accessibility reply becomes MacosAdapterError so the example can SKIP", () => {
  const tools = new LiveMacosNativeTools({
    exec: scripted(() => ({ ok: false, code: "accessibility", message: "손쉬운 사용 권한이 필요합니다." })),
  });
  assert.throws(() => tools.screen_read(), error =>
    error instanceof MacosAdapterError && error.code === "accessibility");
});
