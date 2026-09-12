import assert from "node:assert/strict";
import { test } from "node:test";
import { invokeRunPath, linesFromSpine, previewSpine, textFromSpine, type SpineView } from "./spine.ts";

const missing: SpineView = {
  status: "path_not_found",
  pathId: null,
  note: "no path matched the intent",
  bodyKind: "macos",
  live: false,
  hook: "unused",
  body: null,
};

const done: SpineView = {
  status: "completed",
  pathId: "path-home-next",
  note: "clicked Next",
  bodyKind: "macos",
  live: false,
  hook: "PPOMI_BODY_LIVE=1 npm --prefix shell run host",
  body: { status: "completed", steps: [{ stepId: "open-next", status: "ok", note: "clicked Next" }] },
};

test("path_not_found is a Korean bubble, not a raw status dump", () => {
  assert.equal(textFromSpine(missing), "그 일에 맞는 경로가 아직 없습니다.");
  assert.deepEqual(linesFromSpine(missing), [
    { kind: "bubble", role: "assistant", text: "그 일에 맞는 경로가 아직 없습니다." },
  ]);
});

test("completed path becomes an AI-elements tool card plus a short reply", () => {
  const lines = linesFromSpine(done);
  assert.equal(lines[0]?.kind, "tool");
  assert.equal(lines[1]?.kind, "bubble");
  if (lines[0]?.kind !== "tool" || lines[1]?.kind !== "bubble") return;
  assert.equal(lines[0].tool.name, "run_path");
  assert.equal(lines[0].tool.label, "path-home-next");
  assert.equal(lines[0].tool.state, "output-available");
  assert.equal(lines[1].text, "다음을 눌렀습니다.");
  assert.doesNotMatch(lines[1].text, /status|hook|node host/i);
});

test("preview spine matches host intents", () => {
  assert.equal(previewSpine("다음").status, "completed");
  assert.equal(previewSpine("no-such-path").status, "path_not_found");
});

const ceoIntent = "내 사업자 KB계좌번호 알아?";

test("secrets intent is a tool card plus a masked Korean reply", () => {
  const view = previewSpine(ceoIntent);
  assert.equal(view.status, "completed");
  assert.equal(view.pathId, "path-secrets-account");
  const lines = linesFromSpine(view);
  assert.equal(lines[0]?.kind, "tool");
  assert.equal(lines[1]?.kind, "bubble");
  if (lines[0]?.kind !== "tool" || lines[1]?.kind !== "bubble") return;
  assert.equal(lines[0].tool.name, "run_path");
  assert.equal(lines[0].tool.label, "path-secrets-account");
  assert.equal(lines[1].text, "저장된 사업자 계좌는 `****7890`입니다.");
  const dumped = JSON.stringify(lines);
  assert.doesNotMatch(dumped, /001234567890/);
  assert.doesNotMatch(dumped, /1234567890/);
});

test("run_path IPC failure uses local Korean path_not_found", async () => {
  const bag = globalThis as { __TAURI__?: { core?: { invoke: () => Promise<never> } } };
  const previous = bag.__TAURI__;
  bag.__TAURI__ = {
    core: {
      invoke: async () => {
        throw new Error("node host returned invalid JSON");
      },
    },
  };
  try {
    const view = await invokeRunPath("지금 데이터 뭐 있어?");
    assert.equal(view.status, "path_not_found");
    assert.doesNotMatch(JSON.stringify(view), /invalid JSON|node host/i);
  } finally {
    if (previous === undefined) delete bag.__TAURI__;
    else bag.__TAURI__ = previous;
  }
});

test("preview secrets matcher covers similar Korean and English intents", () => {
  for (const intent of ["KB 계좌번호", "사업자 계좌", "account number", "통장번호"]) {
    assert.equal(previewSpine(intent).pathId, "path-secrets-account", intent);
  }
  assert.equal(previewSpine("알아?").status, "path_not_found");
});
