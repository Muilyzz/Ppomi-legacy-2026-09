import assert from "node:assert/strict";
import { test } from "node:test";
import {
  CEO_GATEWAY_PROMPT,
  GATEWAY_FAIL_TEXT,
  GatewayError,
  SECRETS_CATALOG_INTENT,
  approveChat,
  defaultComplete,
  denyChat,
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

test("CEO Gateway prompt is not a local-only regex match", () => {
  assert.equal(previewSpine(CEO_GATEWAY_PROMPT).status, "path_not_found");
  assert.equal(fixtureIntent(CEO_GATEWAY_PROMPT), SECRETS_CATALOG_INTENT);
});

const homeView: SpineView = {
  status: "completed",
  pathId: "path-home-next",
  note: "step finished",
  bodyKind: "macos",
  live: false,
  hook: "",
  body: { status: "completed", steps: [{ stepId: "open-next", status: "ok", note: "step finished" }] },
  approval: null,
};

const SECRETS_TOKEN = "path-secrets-account/read-account";

const secretsGate: SpineView = {
  status: "needs_human",
  pathId: "path-secrets-account",
  note: `needs_approval: ${SECRETS_TOKEN} (secrets) — nothing executed`,
  bodyKind: "macos",
  live: false,
  hook: "",
  body: {
    status: "stopped",
    steps: [{ stepId: "read-account", status: "needs_human", note: `needs_approval: ${SECRETS_TOKEN} (secrets) — nothing executed` }],
  },
  approval: {
    pathId: "path-secrets-account",
    stepId: "read-account",
    effect: "secrets",
    title: "계좌번호 읽기",
    what: "Keychain / Credential Manager에서 ppomi/kb-star-biz/account를 읽어 마지막 4자리만 보여줍니다.",
    token: SECRETS_TOKEN,
  },
};

/** A host double that gates like the real one: the token unlocks, anything else stops before running. */
function gatedHost(): { runPath: (intent: string, approve?: string) => Promise<SpineView>; calls: { intent: string; approve?: string }[] } {
  const calls: { intent: string; approve?: string }[] = [];
  return {
    calls,
    runPath: async (intent, approve) => {
      calls.push(approve === undefined ? { intent } : { intent, approve });
      if (intent === "다음") return homeView;
      if (approve === SECRETS_TOKEN) return secretsView;
      return secretsGate;
    },
  };
}

test("safe path: a fixture model call for 다음 runs at once — no approval card, no pending", async () => {
  const host = gatedHost();
  let completes = 0;
  const turn = await sendChat("다음", {
    complete: async body => {
      completes += 1;
      return fixtureResponses(body);
    },
    runPath: host.runPath,
  });
  assert.equal(turn.pending, undefined);
  assert.deepEqual(host.calls, [{ intent: "다음" }]);
  assert.equal(completes, 2);
  assert.equal(turn.lines[0]?.kind, "tool");
  if (turn.lines[0]?.kind !== "tool") return;
  assert.equal(turn.lines[0].tool.state, "output-available");
  assert.equal(turn.lines[0].tool.label, "path-home-next");
});

test("secrets read: the model call stops at the gate — 승인 대기 card, nothing executed, no follow-up turn", async () => {
  const host = gatedHost();
  let completes = 0;
  const turn = await sendChat(CEO_GATEWAY_PROMPT, {
    complete: async body => {
      completes += 1;
      return fixtureResponses(body);
    },
    runPath: host.runPath,
  });
  assert.deepEqual(host.calls, [{ intent: SECRETS_CATALOG_INTENT }]);
  assert.equal(completes, 1);
  assert.equal(turn.mode, "gateway");
  assert.equal(turn.pending?.via, "gateway");
  assert.equal(turn.pending?.approval.token, SECRETS_TOKEN);
  assert.match(turn.pending?.prompt ?? "", /승인이 필요합니다.*Keychain.*path-secrets-account · read-account · secrets/);
  assert.equal(turn.lines.length, 1);
  assert.equal(turn.lines[0]?.kind, "tool");
  if (turn.lines[0]?.kind !== "tool") return;
  assert.equal(turn.lines[0].tool.state, "approval-requested");
  assert.equal(turn.lines[0].tool.label, "path-secrets-account");
  assert.deepEqual(turn.lines[0].tool.input, {
    intent: SECRETS_CATALOG_INTENT,
    via: "gateway",
    pathId: "path-secrets-account",
    stepId: "read-account",
    effect: "secrets",
    what: secretsGate.approval?.what,
    token: SECRETS_TOKEN,
  });
  assert.doesNotMatch(JSON.stringify(turn), /\*{4}7890|completed|output-available/);
});

test("실행: approveChat sends the one token back once, then the card completes and the reply is masked", async () => {
  const host = gatedHost();
  const first = await sendChat(CEO_GATEWAY_PROMPT, { complete: async body => fixtureResponses(body), runPath: host.runPath });
  assert.ok(first.pending);
  if (first.pending === undefined) return;
  const turn = await approveChat(first.pending, { complete: async body => fixtureResponses(body), runPath: host.runPath });
  assert.deepEqual(host.calls, [{ intent: SECRETS_CATALOG_INTENT }, { intent: SECRETS_CATALOG_INTENT, approve: SECRETS_TOKEN }]);
  assert.equal(turn.pending, undefined);
  assert.equal(turn.lines[0]?.kind, "tool");
  assert.equal(turn.lines[1]?.kind, "bubble");
  if (turn.lines[0]?.kind !== "tool" || turn.lines[1]?.kind !== "bubble") return;
  assert.equal(turn.lines[0].tool.state, "output-available");
  assert.deepEqual(turn.lines[0].tool.input, { intent: SECRETS_CATALOG_INTENT, via: "gateway" });
  assert.equal(turn.lines[1].text, "저장된 사업자 계좌는 `****7890`입니다.");
  assert.doesNotMatch(JSON.stringify(turn), new RegExp(fixtureAccount));
});

test("취소: denyChat never calls the host and renders 거부됨 honestly", async () => {
  const host = gatedHost();
  const first = await sendChat(CEO_GATEWAY_PROMPT, { complete: async body => fixtureResponses(body), runPath: host.runPath });
  assert.ok(first.pending);
  if (first.pending === undefined) return;
  const turn = denyChat(first.pending);
  assert.deepEqual(host.calls, [{ intent: SECRETS_CATALOG_INTENT }]);
  assert.equal(turn.pending, undefined);
  assert.equal(turn.lines[0]?.kind, "tool");
  assert.equal(turn.lines[1]?.kind, "bubble");
  if (turn.lines[0]?.kind !== "tool" || turn.lines[1]?.kind !== "bubble") return;
  assert.equal(turn.lines[0].tool.state, "output-denied");
  assert.match(turn.lines[0].tool.errorText ?? "", /denied: path-secrets-account\/read-account/);
  assert.equal(turn.lines[1].text, "실행하지 않았습니다.");
  assert.doesNotMatch(JSON.stringify(turn), /\*{4}7890|completed|output-available/);
});

test("a stale token runs nothing: the host gates again and the chat shows a new 승인 대기 card", async () => {
  const host = gatedHost();
  const first = await sendChat(CEO_GATEWAY_PROMPT, { complete: async body => fixtureResponses(body), runPath: host.runPath });
  if (first.pending === undefined) return assert.fail("expected a pending approval");
  const stale = { ...first.pending, approval: { ...first.pending.approval, token: "path-secrets-account/other" } };
  const turn = await approveChat(stale, { complete: async body => fixtureResponses(body), runPath: host.runPath });
  assert.equal(turn.pending?.approval.token, SECRETS_TOKEN);
  assert.equal(turn.lines[0]?.kind === "tool" ? turn.lines[0].tool.state : "", "approval-requested");
  assert.doesNotMatch(JSON.stringify(turn), /\*{4}7890|completed/);
});

test("local fallback is gated the same way and its cards say via local", async () => {
  const host = gatedHost();
  const first = await sendChat("내 사업자 KB계좌번호 알아?", { complete: async () => null, runPath: host.runPath });
  assert.equal(first.mode, "local");
  assert.equal(first.pending?.via, "local");
  assert.equal(first.lines[0]?.kind === "tool" ? first.lines[0].tool.state : "", "approval-requested");
  assert.equal((first.lines[0]?.kind === "tool" ? asInput(first.lines[0].tool.input).via : ""), "local");
  if (first.pending === undefined) return;
  const approved = await approveChat(first.pending, { complete: async () => null, runPath: host.runPath });
  assert.deepEqual(host.calls.at(-1), { intent: "내 사업자 KB계좌번호 알아?", approve: SECRETS_TOKEN });
  assert.equal(approved.mode, "local");
  assert.equal(approved.lines[0]?.kind === "tool" ? approved.lines[0].tool.state : "", "output-available");
  assert.equal(approved.lines[0]?.kind === "tool" ? asInput(approved.lines[0].tool.input).via : "", "local");
  assert.doesNotMatch(JSON.stringify(approved), /"via":"gateway"/);
});

function asInput(input: unknown): Record<string, unknown> {
  return input && typeof input === "object" ? input as Record<string, unknown> : {};
}

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

test("unset Gateway falls back to the local matcher without crashing", async () => {
  const turn = await sendChat(CEO_GATEWAY_PROMPT, {
    complete: async () => null,
    runPath: async intent => previewSpine(intent),
  });
  assert.equal(turn.mode, "local");
  assert.deepEqual(turn.lines, [{
    kind: "bubble",
    role: "assistant",
    text: "그 일에 맞는 경로가 아직 없습니다.",
  }]);
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
