import assert from "node:assert/strict";
import { test } from "node:test";
import {
  CEO_GATEWAY_PROMPT,
  GATEWAY_FAIL_TEXT,
  SECRETS_CATALOG_INTENT,
  defaultComplete,
  fixtureIntent,
  fixtureResponses,
  functionCallOf,
  redactSecrets,
  sendChat,
  toolFromModelCall,
} from "./chat.ts";
import { previewSpine, type SpineView } from "./spine.ts";

const fixtureAccount = "001234567890";

const secretsView: SpineView = {
  status: "completed",
  pathId: "path-secrets-account",
  note: "****7890 ppomi/kb-star-biz/account",
  bodyKind: "macos",
  live: false,
  hook: "",
  body: { status: "completed", steps: [{ stepId: "read-account", status: "ok", note: "****7890 ppomi/kb-star-biz/account" }] },
};

test("CEO paraphrase and catalog intent both select the secrets path", () => {
  assert.equal(previewSpine(CEO_GATEWAY_PROMPT).pathId, "path-secrets-account");
  assert.equal(previewSpine("내 사업자 KB계좌번호 알아?").pathId, "path-secrets-account");
  assert.equal(fixtureIntent(CEO_GATEWAY_PROMPT), SECRETS_CATALOG_INTENT);
  assert.equal(fixtureIntent("내 사업자 KB계좌번호 알아?"), SECRETS_CATALOG_INTENT);
});

test("fixture model calls run_path; ToolCard is from that call, not linesFromSpine(user text)", async () => {
  const intents: string[] = [];
  const turn = await sendChat(CEO_GATEWAY_PROMPT, {
    complete: async body => fixtureResponses(body),
    runPath: async intent => {
      intents.push(intent);
      assert.equal(intent, SECRETS_CATALOG_INTENT);
      return secretsView;
    },
  });
  assert.equal(turn.mode, "gateway");
  assert.equal(turn.lines[0]?.kind, "tool");
  assert.equal(turn.lines[1]?.kind, "bubble");
  if (turn.lines[0]?.kind !== "tool" || turn.lines[1]?.kind !== "bubble") return;
  assert.equal(turn.lines[0].tool.name, "run_path");
  assert.equal(turn.lines[0].tool.label, "path-secrets-account");
  assert.deepEqual(turn.lines[0].tool.input, { intent: SECRETS_CATALOG_INTENT, via: "gateway" });
  assert.equal(turn.lines[1].text, "저장된 사업자 계좌는 `****7890`입니다.");
  assert.deepEqual(intents, [SECRETS_CATALOG_INTENT]);
  const dumped = JSON.stringify(turn);
  assert.doesNotMatch(dumped, new RegExp(fixtureAccount));
  assert.doesNotMatch(dumped, /1234567890/);
});

test("unset Gateway still hits secrets for the CEO paraphrase", async () => {
  const turn = await sendChat(CEO_GATEWAY_PROMPT, {
    complete: async () => null,
    runPath: async intent => previewSpine(intent),
  });
  assert.equal(turn.mode, "local");
  assert.equal(turn.lines[0]?.kind, "tool");
  assert.equal(turn.lines[1]?.kind, "bubble");
  if (turn.lines[0]?.kind !== "tool" || turn.lines[1]?.kind !== "bubble") return;
  assert.equal(turn.lines[0].tool.label, "path-secrets-account");
  assert.equal(turn.lines[1].text, "저장된 사업자 계좌는 `****7890`입니다.");
});

test("configured gateway error throws; unset gateway returns null", async () => {
  const bag = globalThis as { __TAURI__?: { core?: { invoke: (cmd: string, args: Record<string, unknown>) => Promise<unknown> } } };
  const previous = bag.__TAURI__;
  bag.__TAURI__ = {
    core: {
      invoke: async () => ({ configured: true, error: "model_unavailable" }),
    },
  };
  try {
    await assert.rejects(defaultComplete({ input: "x" }), /model_unavailable/);
    bag.__TAURI__ = {
      core: {
        invoke: async () => ({ configured: false }),
      },
    };
    assert.equal(await defaultComplete({ input: "x" }), null);
  } finally {
    if (previous === undefined) delete bag.__TAURI__;
    else bag.__TAURI__ = previous;
  }
});

test("gateway proxy IPC failure is a distinct error, not path_not_found", async () => {
  const turn = await sendChat("지금 데이터 뭐 있어?", {
    complete: async () => {
      throw new Error("node host returned invalid JSON");
    },
    runPath: async () => {
      throw new Error("run_path should not run after gateway ipc fail");
    },
  });
  assert.equal(turn.mode, "gateway");
  assert.deepEqual(turn.lines, [{
    kind: "bubble",
    role: "assistant",
    text: GATEWAY_FAIL_TEXT,
  }]);
  assert.doesNotMatch(JSON.stringify(turn), /invalid JSON|node host|그 일에 맞는 경로/i);
});

test("local fallback still paints the CEO regex intent as a secrets card", async () => {
  const turn = await sendChat("내 사업자 KB계좌번호 알아?", {
    complete: async () => null,
    runPath: async intent => previewSpine(intent),
  });
  assert.equal(turn.mode, "local");
  assert.equal(turn.lines[0]?.kind, "tool");
  if (turn.lines[0]?.kind !== "tool") return;
  assert.equal(turn.lines[0].tool.input && typeof turn.lines[0].tool.input === "object" && "via" in turn.lines[0].tool.input, false);
});

test("toolFromModelCall marks via gateway and redacts long digits", () => {
  const dirty: SpineView = { ...secretsView, note: `${fixtureAccount} leaked` };
  const tool = toolFromModelCall({ name: "run_path", intent: SECRETS_CATALOG_INTENT }, dirty);
  assert.deepEqual(tool.input, { intent: SECRETS_CATALOG_INTENT, via: "gateway" });
  assert.doesNotMatch(JSON.stringify(tool), new RegExp(fixtureAccount));
  assert.match(redactSecrets(fixtureAccount), /\*{4}7890/);
});

test("functionCallOf reads the Responses function_call", () => {
  const call = functionCallOf(fixtureResponses({ input: CEO_GATEWAY_PROMPT }));
  assert.deepEqual(call, { call_id: "call_run_path", name: "run_path", intent: SECRETS_CATALOG_INTENT });
});

test("fixture Gateway keeps KB open off the secrets remap", async () => {
  const kbOpen = "KB스타기업뱅킹 열어";
  assert.equal(fixtureIntent(kbOpen), kbOpen);
  assert.equal(fixtureIntent("내 사업자 KB계좌번호 알아?"), SECRETS_CATALOG_INTENT);
  const turn = await sendChat(kbOpen, {
    complete: async body => fixtureResponses(body),
    runPath: async intent => previewSpine(intent),
  });
  assert.equal(turn.mode, "gateway");
  assert.equal(turn.lines[0]?.kind, "tool");
  assert.equal(turn.lines[1]?.kind, "bubble");
  if (turn.lines[0]?.kind !== "tool" || turn.lines[1]?.kind !== "bubble") return;
  assert.equal(turn.lines[0].tool.label, "kb-star-biz-iphone");
  assert.equal(turn.lines[0].tool.state, "output-available");
  assert.deepEqual(turn.lines[0].tool.input, { intent: kbOpen, via: "gateway" });
  assert.equal(turn.lines[1].text, "KB스타기업뱅킹을 열었습니다. Face ID로 로그인하면 이어서 볼게요.");
  assert.doesNotMatch(JSON.stringify(turn), /path_not_found|1234567890|\*{4}7890/);
});

test("fixture Gateway still returns ****7890 for the exact secrets phrase", async () => {
  const turn = await sendChat("내 사업자 KB계좌번호 알아?", {
    complete: async body => fixtureResponses(body),
    runPath: async intent => previewSpine(intent),
  });
  assert.equal(turn.mode, "gateway");
  assert.equal(turn.lines[0]?.kind, "tool");
  assert.equal(turn.lines[1]?.kind, "bubble");
  if (turn.lines[0]?.kind !== "tool" || turn.lines[1]?.kind !== "bubble") return;
  assert.equal(turn.lines[0].tool.label, "path-secrets-account");
  assert.deepEqual(turn.lines[0].tool.input, { intent: SECRETS_CATALOG_INTENT, via: "gateway" });
  assert.equal(turn.lines[1].text, "저장된 사업자 계좌는 `****7890`입니다.");
});
