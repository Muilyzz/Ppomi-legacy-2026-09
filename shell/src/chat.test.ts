import assert from "node:assert/strict";
import { test } from "node:test";
import {
  CEO_GATEWAY_PROMPT,
  GATEWAY_FAIL_TEXT,
  GatewayError,
  SECRETS_CATALOG_INTENT,
  defaultComplete,
  fixtureIntent,
  fixtureResponses,
  functionCallOf,
  gatewayFailText,
  redactSecrets,
  sendChat,
  toolFromModelCall,
} from "./chat.ts";
import { previewSpine, type SpineView } from "./spine.ts";

const fixtureAccount = "001234567890";

type Invoke = (cmd: string, args: Record<string, unknown>) => Promise<unknown>;
const bag = globalThis as { __TAURI__?: { core?: { invoke: Invoke } } };

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

test("gateway IPC failure is a visible gateway error with its code — no regex fallback, no run_path", async () => {
  const restore = quietConsole();
  try {
    for (const text of ["다음", "내 사업자 KB계좌번호 알아?", "지금 데이터 뭐 있어?"]) {
      const turn = await sendChat(text, {
        complete: async () => {
          throw new GatewayError("gateway_host_failed", "node host returned invalid JSON; stderr=boom");
        },
        runPath: async () => {
          throw new Error("run_path must not run after a gateway failure");
        },
      });
      assert.equal(turn.mode, "gateway", text);
      assert.deepEqual(turn.lines, [{
        kind: "bubble",
        role: "assistant",
        text: gatewayFailText("gateway_host_failed"),
      }]);
      assert.match(turn.lines[0]?.kind === "bubble" ? turn.lines[0].text : "", /게이트웨이 오류: gateway_host_failed/);
      assert.match(turn.lines[0]?.kind === "bubble" ? turn.lines[0].text : "", new RegExp(GATEWAY_FAIL_TEXT));
      assert.doesNotMatch(JSON.stringify(turn), /invalid JSON|node host|boom|그 일에 맞는 경로|다음을 눌렀습니다|\*{4}7890|completed/i);
    }
  } finally {
    restore();
  }
});

test("a plain thrown Error from complete() still surfaces as a coded gateway failure", async () => {
  const restore = quietConsole();
  try {
    const turn = await sendChat("다음", {
      complete: async () => {
        throw new Error("node host returned invalid JSON");
      },
      runPath: async () => {
        throw new Error("run_path must not run after a gateway failure");
      },
    });
    assert.equal(turn.mode, "gateway");
    assert.deepEqual(turn.lines, [{ kind: "bubble", role: "assistant", text: gatewayFailText("gateway_failed") }]);
  } finally {
    restore();
  }
});

test("defaultComplete: IPC rejection and configured proxy errors throw GatewayError; unset gateway is null", async () => {
  await withTauri(
    async () => {
      throw { code: "gateway_host_failed", message: "node host failed to start (/opt/homebrew/bin/node): ENOENT" };
    },
    async () => {
      await assert.rejects(defaultComplete({ input: "x" }), (error: unknown) =>
        error instanceof GatewayError && error.code === "gateway_host_failed");
    },
  );
  await withTauri(
    async () => ({ configured: true, error: "model_unavailable" }),
    async () => {
      await assert.rejects(defaultComplete({ input: "x" }), (error: unknown) =>
        error instanceof GatewayError && error.code === "model_unavailable");
    },
  );
  await withTauri(
    async () => ({ configured: true }),
    async () => {
      await assert.rejects(defaultComplete({ input: "x" }), /model_unavailable/);
    },
  );
  await withTauri(
    async () => ({ configured: false }),
    async () => {
      assert.equal(await defaultComplete({ input: "x" }), null);
    },
  );
});

test("a failed follow-up narration keeps the tool card and names the gateway error", async () => {
  const restore = quietConsole();
  try {
    let calls = 0;
    const turn = await sendChat(CEO_GATEWAY_PROMPT, {
      complete: async body => {
        calls += 1;
        if (calls === 1) return fixtureResponses(body);
        throw new GatewayError("model_unavailable");
      },
      runPath: async () => secretsView,
    });
    assert.equal(turn.mode, "gateway");
    assert.equal(turn.lines[0]?.kind, "tool");
    assert.equal(turn.lines[1]?.kind, "bubble");
    if (turn.lines[1]?.kind !== "bubble") return;
    assert.equal(turn.lines[1].text, "저장된 사업자 계좌는 `****7890`입니다. (게이트웨이 오류: model_unavailable)");
  } finally {
    restore();
  }
});

test("local fallback (no gateway configured) labels its card via local, never via gateway", async () => {
  const turn = await sendChat("내 사업자 KB계좌번호 알아?", {
    complete: async () => null,
    runPath: async intent => previewSpine(intent),
  });
  assert.equal(turn.mode, "local");
  assert.equal(turn.lines[0]?.kind, "tool");
  if (turn.lines[0]?.kind !== "tool") return;
  assert.deepEqual(turn.lines[0].tool.input, { body: "macos", live: false, via: "local" });
  assert.doesNotMatch(JSON.stringify(turn), /"via":"gateway"/);
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
