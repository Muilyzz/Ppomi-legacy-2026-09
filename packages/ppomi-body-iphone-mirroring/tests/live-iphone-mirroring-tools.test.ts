import assert from "node:assert/strict";
import { test } from "node:test";
import {
  FixedPermissionGate,
  OsSurface,
  Runtime,
} from "../../ppomi-body/src/index.ts";
import {
  IphoneMirroringAdapterError,
  IphoneMirroringDriver,
  LiveIphoneMirroringTools,
  axHasPhoneLabels,
  isPayWord,
  liveIphoneRequested,
  skipCode,
  type LiveIphoneAxNode,
  type LiveIphoneCommand,
  type LiveIphoneExec,
  type LiveIphoneOcrNode,
  type LiveIphoneReply,
} from "../src/index.ts";

const chromeHome: LiveIphoneAxNode = {
  text: "Home",
  role: "button",
  clickable: true,
  editable: false,
  password: false,
  bounds: { left: 20, top: 700, right: 80, bottom: 740 },
};

const accounts: LiveIphoneAxNode = {
  text: "계좌조회",
  role: "button",
  clickable: true,
  editable: false,
  password: false,
  bounds: { left: 20, top: 200, right: 180, bottom: 236 },
};

const heading: LiveIphoneAxNode = {
  text: "계좌번호",
  role: "text",
  clickable: false,
  editable: false,
  password: false,
  bounds: { left: 20, top: 80, right: 200, bottom: 110 },
};

const account: LiveIphoneAxNode = {
  text: "001234567890",
  role: "text",
  clickable: true,
  editable: false,
  password: false,
  bounds: { left: 20, top: 120, right: 280, bottom: 150 },
};

const pay: LiveIphoneAxNode = {
  text: "이체",
  role: "button",
  clickable: true,
  editable: false,
  password: false,
  bounds: { left: 20, top: 400, right: 100, bottom: 432 },
};

function scripted(handler: (command: LiveIphoneCommand) => LiveIphoneReply): LiveIphoneExec {
  return handler;
}

function axReply(nodes: readonly LiveIphoneAxNode[], appLabel = "iPhone Mirroring"): LiveIphoneReply {
  return { ok: true, result: { appLabel, source: "ax", nodes } };
}

function ocrReply(nodes: readonly LiveIphoneOcrNode[]): LiveIphoneReply {
  return { ok: true, result: { appLabel: "iPhone Mirroring", source: "ocr", ocr: nodes } };
}

test("pay word / chrome / live flag / skip codes", () => {
  assert.equal(isPayWord("이체"), true);
  assert.equal(isPayWord("바로구매"), false);
  assert.equal(axHasPhoneLabels([chromeHome]), false);
  assert.equal(axHasPhoneLabels([chromeHome, accounts]), true);
  assert.equal(liveIphoneRequested({ PPOMI_BODY_LIVE: "1" }), true);
  assert.equal(liveIphoneRequested({ PPOMI_BODY_LIVE: "0" }), false);
  assert.equal(skipCode("osascript is not allowed assistive access. (-25211)"), "accessibility");
  assert.equal(skipCode("phone CLI not built"), "no_phone_cli");
});

test("AX phone labels win; chrome-only falls through to OCR", () => {
  const commands: LiveIphoneCommand[] = [];
  const tools = new LiveIphoneMirroringTools({
    exec: scripted(command => {
      commands.push(command);
      if (command.op === "read_ax") return axReply([chromeHome]);
      if (command.op === "read_ocr") return ocrReply([{ text: "계좌조회", x: 0.3, y: 0.28, w: 0.2, h: 0.04 }]);
      return { ok: false, code: "failed", message: command.op };
    }),
  });
  const screen = tools.phone_screen();
  assert.equal(screen.rows.some(row => row.text === "계좌조회" && row.tappable), true);
  assert.equal(commands.some(command => command.op === "read_ocr"), true);

  const axOnly = new LiveIphoneMirroringTools({
    exec: scripted(command => {
      if (command.op === "read_ax") return axReply([heading, accounts]);
      return { ok: false, code: "failed", message: "ocr must not run when AX has phone labels" };
    }),
  });
  assert.deepEqual(axOnly.phone_screen().rows.map(row => row.text), ["계좌번호", "계좌조회"]);
});

test("phone_screen masks the account; tap of pay / account is refused", () => {
  const commands: LiveIphoneCommand[] = [];
  const tools = new LiveIphoneMirroringTools({
    exec: scripted(command => {
      commands.push(command);
      if (command.op === "read_ax") return axReply([heading, account, accounts, pay]);
      if (command.op === "tap_ax") return { ok: true, result: { invoked: true } };
      return { ok: false, code: "failed", message: JSON.stringify(command) };
    }),
  });
  const screen = tools.phone_screen();
  const raw = JSON.stringify(screen);
  assert.equal(raw.includes("001234567890"), false);
  assert.equal(screen.rows.some(row => row.text === "****7890"), true);
  assert.equal(screen.rows.find(row => row.text === "****7890")?.tappable, false);
  assert.throws(() => tools.phone_tap({ text: "이체" }), error =>
    error instanceof IphoneMirroringAdapterError && error.code === "protected_action");
  assert.throws(() => tools.phone_tap({ text: "****7890" }), error =>
    error instanceof IphoneMirroringAdapterError && error.code === "protected_action");
  assert.deepEqual(tools.phone_tap({ text: "계좌조회" }), { tapped: true });
  assert.equal(
    commands.some(command => command.op === "tap_ax" && command.label === "계좌조회"),
    true,
  );
});

test("Runtime read + capture port keep the raw number off StepResult", async () => {
  const tools = new LiveIphoneMirroringTools({
    exec: scripted(command => {
      if (command.op === "read_ax") return axReply([heading, account, accounts]);
      return { ok: false, code: "failed", message: command.op };
    }),
  });
  const preview = tools.phone_screen();
  assert.deepEqual(tools.capture.peekMasked(), { masked: "****7890", last4: "7890" });

  const result = await new Runtime(
    new OsSurface(new IphoneMirroringDriver(tools)),
    new FixedPermissionGate(["ui.read"]),
  ).run({
    id: "kb-star-biz-iphone",
    steps: [{ id: "read-account", kind: "read", require: { screen: ["계좌번호"] } }],
  });

  assert.equal(result.status, "completed");
  assert.equal(result.stepResults[0]?.driver, "phone");
  const dumped = JSON.stringify(result);
  assert.equal(dumped.includes("001234567890"), false);
  assert.equal(preview.rows.some(row => row.text === "****7890"), true);
  assert.ok(result.evidence[0]?.screenTexts.includes("****7890"));
});
