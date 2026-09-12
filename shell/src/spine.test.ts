import assert from "node:assert/strict";
import { test } from "node:test";
import {
  RUN_PATH_IPC_FAILED,
  errorCodeOf,
  invokeRunPath,
  linesFromSpine,
  previewSpine,
  textFromSpine,
  toolFromSpine,
  type SpineView,
} from "./spine.ts";

type Invoke = (cmd: string, args: Record<string, unknown>) => Promise<unknown>;
const bag = globalThis as { __TAURI__?: { core?: { invoke: Invoke } }; location?: { search?: string } };

async function withTauri<T>(invoke: Invoke, run: () => Promise<T>): Promise<T> {
  const previous = bag.__TAURI__;
  bag.__TAURI__ = { core: { invoke } };
  try {
    return await run();
  } finally {
    if (previous === undefined) delete bag.__TAURI__;
    else bag.__TAURI__ = previous;
  }
}

const quietConsole = (): (() => void) => {
  const original = console.error;
  console.error = () => {};
  return () => {
    console.error = original;
  };
};

/** What a broken host must never produce: a green card or the preview's canned sentences. */
function assertNothingFabricated(view: SpineView): void {
  assert.notEqual(view.status, "completed");
  assert.equal(view.pathId, null);
  const dumped = JSON.stringify([view, linesFromSpine(view)]);
  assert.doesNotMatch(dumped, /completed|다음을 눌렀습니다|\*{4}7890|clicked Next|ppomi\/kb-star-biz/);
}

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

test("run_path IPC failure is failed with the code — never the preview's fabricated completed", async () => {
  const restore = quietConsole();
  try {
    for (const intent of ["다음", "내 사업자 KB계좌번호 알아?", "지금 데이터 뭐 있어?"]) {
      const view = await withTauri(
        async () => {
          throw { code: "run_path_host_failed", message: "node host returned invalid JSON; stderr=boom" };
        },
        () => invokeRunPath(intent),
      );
      assert.equal(view.status, "failed", intent);
      assert.equal(view.note, `${RUN_PATH_IPC_FAILED}: run_path_host_failed`, intent);
      assert.equal(textFromSpine(view), "실행에 실패했습니다.");
      assertNothingFabricated(view);
      const lines = linesFromSpine(view);
      assert.equal(lines[0]?.kind, "tool");
      if (lines[0]?.kind !== "tool") return;
      assert.equal(lines[0].tool.state, "output-error");
      assert.match(lines[0].tool.errorText ?? "", /run_path_host_failed/);
      assert.doesNotMatch(JSON.stringify(view), /invalid JSON|node host|boom|그 일에 맞는 경로/i);
    }
  } finally {
    restore();
  }
});

test("an IPC rejection without a code still fails honestly under a fallback code", async () => {
  const restore = quietConsole();
  try {
    const view = await withTauri(
      async () => {
        throw new Error("node host returned invalid JSON");
      },
      () => invokeRunPath("다음"),
    );
    assert.equal(view.status, "failed");
    assert.equal(view.note, `${RUN_PATH_IPC_FAILED}: ipc_rejected`);
    assertNothingFabricated(view);
  } finally {
    restore();
  }
});

test("no Tauri IPC outside the dev preview is failed no_tauri_ipc, not a preview run", async () => {
  assert.equal(bag.__TAURI__, undefined);
  assert.equal(bag.location, undefined);
  const view = await invokeRunPath("다음");
  assert.equal(view.status, "failed");
  assert.equal(view.note, `${RUN_PATH_IPC_FAILED}: no_tauri_ipc`);
  assertNothingFabricated(view);
});

test("?chat=fixture without Tauri is the preview, and it says so", async () => {
  bag.location = { search: "?chat=fixture" };
  try {
    const view = await invokeRunPath("다음");
    assert.equal(view.preview, true);
    assert.equal(view.status, "completed");
    assert.equal(textFromSpine(view), "(미리보기) 다음을 눌렀습니다.");
    assert.deepEqual(toolFromSpine(view)?.input, { body: "macos", live: false, preview: true });
  } finally {
    delete bag.location;
  }
});

test("errorCodeOf reads Rust { code } objects, code: message strings, and falls back", () => {
  assert.equal(errorCodeOf({ code: "gateway_host_failed", message: "x" }, "fallback"), "gateway_host_failed");
  assert.equal(errorCodeOf("host_timeout: node host did not finish", "fallback"), "host_timeout");
  assert.equal(errorCodeOf(new Error("model_unavailable"), "fallback"), "model_unavailable");
  assert.equal(errorCodeOf(new Error("node host returned invalid JSON"), "fallback"), "fallback");
  assert.equal(errorCodeOf(undefined, "fallback"), "fallback");
});

test("preview secrets matcher covers similar Korean and English intents", () => {
  for (const intent of [
    "KB 계좌번호",
    "사업자 계좌",
    "account number",
    "통장번호",
    "KB스타비즈에 넣어둔 번호 마지막만 보여줘",
  ]) {
    assert.equal(previewSpine(intent).pathId, "path-secrets-account", intent);
  }
  assert.equal(previewSpine("알아?").status, "path_not_found");
  assert.equal(previewSpine("지금 데이터 뭐 있어?").status, "path_not_found");
});

test("KB open intents are a tool card plus a short Korean Face ID bubble", () => {
  for (const intent of ["KB스타기업뱅킹 열어", "KB 사업자 홈", "path_cold_start"]) {
    const view = previewSpine(intent);
    assert.equal(view.status, "needs_human", intent);
    assert.equal(view.pathId, "kb-star-biz-iphone", intent);
    const lines = linesFromSpine(view);
    assert.equal(lines[0]?.kind, "tool");
    assert.equal(lines[1]?.kind, "bubble");
    if (lines[0]?.kind !== "tool" || lines[1]?.kind !== "bubble") return;
    assert.equal(lines[0].tool.name, "run_path");
    assert.equal(lines[0].tool.label, "kb-star-biz-iphone");
    assert.equal(lines[0].tool.state, "output-available");
    assert.equal(lines[1].text, "KB스타기업뱅킹을 열었습니다. Face ID로 로그인하면 이어서 볼게요.");
    const dumped = JSON.stringify(lines);
    assert.doesNotMatch(dumped, /001234567890|1234567890/);
    assert.doesNotMatch(dumped, /path_not_found/);
  }
  assert.equal(previewSpine("열어").pathId, "path-home-next");
});
