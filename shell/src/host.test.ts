import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { mkdirSync, mkdtempSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { test } from "node:test";
import { gatewayConfig, parseGatewayEnvFile, processGatewayKey, proxyResponses } from "./gateway.ts";
import { verifyClerkSession } from "./clerk-session.ts";
import { KB_STAR_BIZ_PATH_ID, parseArgs, parseBodyKind, runSpine, secretsPath } from "./host.ts";

const hostFile = join(dirname(fileURLToPath(import.meta.url)), "host.ts");

test("macos fixture 1-step reaches ppomi-body-macos through brain", async () => {
  const result = await runSpine({ intent: "다음", body: "macos", live: false });
  assert.equal(result.status, "completed");
  assert.equal(result.pathId, "path-home-next");
  assert.equal(result.bodyKind, "macos");
  assert.equal(result.body?.status, "completed");
  assert.equal(result.body?.steps[0]?.status, "ok");
  assert.match(result.hook, /PPOMI_BODY_LIVE=1/);
});

test("unknown intent never calls body", async () => {
  const result = await runSpine({ intent: "no-such-path", body: "macos", live: false });
  assert.equal(result.status, "path_not_found");
  assert.equal(result.body, null);
});

test("host CLI exits 0 and prints JSON when no path matches", () => {
  const result = spawnSync(process.execPath, ["--experimental-strip-types", hostFile, "--intent", "no-such-path"], {
    encoding: "utf8",
    cwd: join(dirname(hostFile), ".."),
  });
  assert.equal(result.status, 0, result.stderr);
  const body = JSON.parse(result.stdout) as { status: string };
  assert.equal(body.status, "path_not_found");
});

test("windows and android fixtures share the same spine IPC", async () => {
  const windows = await runSpine({ intent: "browse", body: "windows", live: false });
  const android = await runSpine({ intent: "home", body: "android", live: false });
  assert.equal(windows.status, "completed");
  assert.equal(android.status, "completed");
  assert.equal(windows.bodyKind, "windows");
  assert.equal(android.bodyKind, "android");
});

test("live macos off-darwin skips instead of failing", async () => {
  if (process.platform === "darwin") return;
  const result = await runSpine({ intent: "다음", body: "macos", live: true });
  assert.equal(result.status, "completed");
  assert.match(result.note, /not darwin/);
});

test("parseArgs reads intent, body, and live", () => {
  assert.equal(parseBodyKind(undefined), "macos");
  assert.deepEqual(parseArgs(["열어", "--body", "windows", "--live"]), {
    intent: "열어",
    body: "windows",
    live: true,
  });
});

const ceoIntent = "내 사업자 KB계좌번호 알아?";
const fixtureAccount = "001234567890";

function assertMaskedAccount(result: { status: string; pathId: string | null; note: string; body: { steps: readonly { note: string }[] } | null }): void {
  assert.equal(result.status, "completed");
  assert.equal(result.pathId, secretsPath.id);
  assert.match(result.note, /\*{4}7890/);
  assert.match(result.body?.steps[0]?.note ?? "", /\*{4}7890/);
  const dumped = JSON.stringify(result);
  assert.doesNotMatch(dumped, new RegExp(fixtureAccount));
  assert.doesNotMatch(dumped, /1234567890/);
}

test("Korean business-account intents choose the secrets path", async () => {
  for (const intent of [
    ceoIntent,
    "KB스타비즈에 넣어둔 번호 마지막만 보여줘",
    "KB 계좌번호",
    "사업자 계좌 알려줘",
    "account number",
    "통장번호",
  ]) {
    const result = await runSpine({ intent, body: "macos", live: false });
    assertMaskedAccount(result);
  }
});

test("host CLI exits 0 for the CEO secrets intent and prints no plaintext", () => {
  const result = spawnSync(
    process.execPath,
    ["--experimental-strip-types", hostFile, "--intent", ceoIntent],
    {
      encoding: "utf8",
      cwd: join(dirname(hostFile), ".."),
    },
  );
  assert.equal(result.status, 0, result.stderr);
  const body = JSON.parse(result.stdout) as {
    status: string;
    pathId: string | null;
    note: string;
    body: { steps: readonly { note: string }[] } | null;
  };
  assertMaskedAccount(body);
});

test("bare 알아 stays path_not_found", async () => {
  const result = await runSpine({ intent: "알아?", body: "macos", live: false });
  assert.equal(result.status, "path_not_found");
});

test("fixture CLI proxy answers 안녕 as secretary text, not run_path", async () => {
  const result = await proxyResponses(
    { input: [{ role: "user", content: "안녕" }], model: "client", stream: true, store: true },
    { env: { PPOMI_CHAT: "fixture" } },
  );
  assert.equal(result.configured, true);
  assert.equal(result.fixture, true);
  assert.equal("error" in result, false);
  assert.ok(result.response);
  const dumped = JSON.stringify(result);
  assert.match(dumped, /안녕하세요\. 무엇을 도와드릴까요\?/);
  assert.doesNotMatch(dumped, /function_call|run_path|path_not_found|그 일에 맞는 경로/);
});

test("host CLI --proxy-responses fixture 너 모델 뭐야? is secretary text", () => {
  const result = spawnHost(
    hostFile,
    ["--proxy-responses"],
    { AI_GATEWAY_API_KEY: "", PPOMI_CHAT: "fixture" },
    "{\"input\":[{\"role\":\"user\",\"content\":\"너 모델 뭐야?\"}]}\n",
  );
  assert.equal(result.status, 0, result.stderr);
  const dumped = result.stdout;
  assert.match(dumped, /뽀미입니다/);
  assert.doesNotMatch(dumped, /function_call|run_path|path_not_found|그 일에 맞는 경로/);
});

test("host CLI --proxy-responses fixture 안녕 is a secretary message", () => {
  const result = spawnHost(
    hostFile,
    ["--proxy-responses"],
    { AI_GATEWAY_API_KEY: "", PPOMI_CHAT: "fixture" },
    "{\"input\":[{\"role\":\"user\",\"content\":\"안녕\"}]}\n",
  );
  assert.equal(result.status, 0, result.stderr);
  const body = JSON.parse(result.stdout) as {
    configured: boolean;
    fixture?: boolean;
    response?: { output?: readonly { type?: string; name?: string }[] };
  };
  assert.equal(body.configured, true);
  assert.equal(body.fixture, true);
  assert.equal(body.response?.output?.[0]?.type, "message");
  assert.doesNotMatch(result.stdout, /function_call|run_path|path_not_found|그 일에 맞는 경로/);
});

test("gateway probe is configured only when a key or fixture is set", async () => {
  const off = await proxyResponses({ probe: true }, { env: {} });
  assert.deepEqual(off, { configured: false, fixture: false });
  const fixture = await proxyResponses({ probe: true }, { env: { PPOMI_CHAT: "fixture" } });
  assert.deepEqual(fixture, { configured: true, fixture: true });
  const live = await proxyResponses({ probe: true }, { env: { AI_GATEWAY_API_KEY: "k" } });
  assert.equal(live.configured, true);
  assert.equal(live.fixture, false);
  assert.equal(processGatewayKey({ AI_GATEWAY_API_KEY: "k" }), "k");
});

function testClerkJwt(payload: Record<string, unknown> = {}): string {
  const body = {
    sub: "user_2AbCdEfGhIjK",
    exp: Math.floor(Date.now() / 1000) + 86400,
    iss: "https://foo.clerk.accounts.dev",
    ...payload,
  };
  const header = Buffer.from(JSON.stringify({ alg: "none", typ: "JWT" })).toString("base64url");
  return `${header}.${Buffer.from(JSON.stringify(body)).toString("base64url")}.sig`;
}

test("HOME/.ppomi/.env supplies the Gateway key when process env is empty", async () => {
  const home = mkdtempSync(join(tmpdir(), "ppomi-home-"));
  try {
    mkdirSync(join(home, ".ppomi"), { mode: 0o700 });
    writeFileSync(
      join(home, ".ppomi", ".env"),
      "VERCEL_OIDC_TOKEN=unused-oidc\nAI_GATEWAY_API_KEY=file-secret-key\n",
      { mode: 0o600 },
    );
    assert.equal(parseGatewayEnvFile("VERCEL_OIDC_TOKEN=unused-oidc\n").AI_GATEWAY_API_KEY, undefined);
    assert.equal(gatewayConfig({ HOME: home })?.key, "file-secret-key");
    assert.equal(processGatewayKey({ HOME: home }), undefined);
    const unsigned = await proxyResponses({ probe: true }, { env: { HOME: home } });
    assert.deepEqual(unsigned, { configured: false, fixture: false });
    const session = testClerkJwt();
    assert.equal(verifyClerkSession(session), true);
    const probe = await proxyResponses(
      { probe: true, clerkSession: session },
      { env: { HOME: home } },
    );
    assert.deepEqual(probe, { configured: true, fixture: false });
    const fixtureWins = await proxyResponses({ probe: true }, {
      env: { HOME: home, PPOMI_CHAT: "fixture" },
    });
    assert.deepEqual(fixtureWins, { configured: true, fixture: true });
    assert.equal(gatewayConfig({ HOME: home, AI_GATEWAY_API_KEY: "process-key" })?.key, "process-key");
    assert.doesNotMatch(JSON.stringify(probe), /file-secret-key|unused-oidc|clerkSession|user_2/);
  } finally {
    rmSync(home, { recursive: true, force: true });
  }
});

test("PPOMI_ROOT/shell/.env is the repo fallback when HOME file has no key", async () => {
  const root = mkdtempSync(join(tmpdir(), "ppomi-root-"));
  try {
    mkdirSync(join(root, "shell"));
    writeFileSync(join(root, "shell", ".env"), "AI_GATEWAY_API_KEY=root-secret-key\n", { mode: 0o600 });
    assert.equal(gatewayConfig({ HOME: root, PPOMI_ROOT: root })?.key, "root-secret-key");
    assert.equal(gatewayConfig({ HOME: root }), null);
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

test("file Gateway key is unused until a Clerk session is verified", async () => {
  const home = mkdtempSync(join(tmpdir(), "ppomi-clerk-gate-"));
  const calls: string[] = [];
  try {
    mkdirSync(join(home, ".ppomi"), { mode: 0o700 });
    writeFileSync(join(home, ".ppomi", ".env"), "AI_GATEWAY_API_KEY=file-secret-key\n", { mode: 0o600 });
    const blocked = await proxyResponses(
      { input: [{ role: "user", content: "너 모델 뭐야?" }], clerkSession: "not-a-jwt" },
      {
        env: { HOME: home },
        fetch: async url => {
          calls.push(String(url));
          return new Response("{}", { status: 200 });
        },
      },
    );
    assert.deepEqual(blocked, { configured: false, fixture: false });
    assert.equal(calls.length, 0);
    const session = testClerkJwt();
    const result = await proxyResponses(
      { input: [{ role: "user", content: "너 모델 뭐야?" }], clerkSession: session, model: "client" },
      {
        env: { HOME: home },
        fetch: async (url, init) => {
          calls.push(String(url));
          const sent = JSON.parse(String(init?.body)) as Record<string, unknown>;
          assert.equal("clerkSession" in sent, false);
          assert.equal("probe" in sent, false);
          assert.doesNotMatch(JSON.stringify(sent), /file-secret-key|user_2AbCdEfGhIjK/);
          return new Response(JSON.stringify({ output: [] }), { status: 200, headers: { "content-type": "application/json" } });
        },
      },
    );
    assert.equal(result.configured, true);
    assert.equal(calls.length, 1);
    assert.doesNotMatch(JSON.stringify(result), /file-secret-key|clerkSession|user_2AbCdEfGhIjK/);
  } finally {
    rmSync(home, { recursive: true, force: true });
  }
});

test("gateway proxy posts to the AI Gateway and never echoes the key", async () => {
  const calls: { url: string; init: RequestInit }[] = [];
  const result = await proxyResponses(
    { input: [{ role: "user", content: "hi" }], model: "client-chosen", stream: true, store: true },
    {
      env: { AI_GATEWAY_API_KEY: "secret-key", AI_TEXT_MODEL: "openai/gpt-6-astra" },
      fetch: async (url, init) => {
        calls.push({ url: String(url), init: init ?? {} });
        return new Response(JSON.stringify({ output: [] }), { status: 200, headers: { "content-type": "application/json" } });
      },
    },
  );
  assert.equal(result.configured, true);
  assert.equal(calls.length, 1);
  assert.equal(calls[0]?.url, "https://ai-gateway.vercel.sh/v1/responses");
  const sent = JSON.parse(String(calls[0]?.init.body)) as { model: string; stream: boolean; store: boolean };
  assert.equal(sent.model, "openai/gpt-6-astra");
  assert.equal(sent.stream, false);
  assert.equal(sent.store, false);
  assert.doesNotMatch(JSON.stringify(result), /secret-key/);
});

test("host CLI --proxy-responses reads ~/.ppomi/.env without echoing the key", () => {
  const home = mkdtempSync(join(tmpdir(), "ppomi-cli-home-"));
  try {
    mkdirSync(join(home, ".ppomi"), { mode: 0o700 });
    writeFileSync(join(home, ".ppomi", ".env"), "AI_GATEWAY_API_KEY=cli-file-secret\n", { mode: 0o600 });
    const unsigned = spawnHost(
      hostFile,
      ["--proxy-responses"],
      { HOME: home, PPOMI_ROOT: "", AI_GATEWAY_API_KEY: "", PPOMI_CHAT: "", CLERK_SESSION: "" },
      "{\"probe\":true}\n",
    );
    assert.equal(unsigned.status, 0, unsigned.stderr);
    assert.equal((JSON.parse(unsigned.stdout) as { configured: boolean }).configured, false);
    writeFileSync(join(home, ".ppomi", "clerk-session"), testClerkJwt(), { mode: 0o600 });
    const result = spawnHost(
      hostFile,
      ["--proxy-responses"],
      { HOME: home, PPOMI_ROOT: "", AI_GATEWAY_API_KEY: "", PPOMI_CHAT: "", CLERK_SESSION: "" },
      "{\"probe\":true}\n",
    );
    assert.equal(result.status, 0, result.stderr);
    const body = JSON.parse(result.stdout) as { configured: boolean; fixture?: boolean };
    assert.equal(body.configured, true);
    assert.equal(body.fixture, false);
    assert.doesNotMatch(result.stdout, /cli-file-secret|user_2AbCdEfGhIjK/);
  } finally {
    rmSync(home, { recursive: true, force: true });
  }
});

test("host CLI --proxy-responses probe exits 0 without a key", () => {
  const home = mkdtempSync(join(tmpdir(), "ppomi-empty-home-"));
  try {
    const result = spawnSync(
      process.execPath,
      ["--experimental-strip-types", hostFile, "--proxy-responses"],
      {
        encoding: "utf8",
        cwd: join(dirname(hostFile), ".."),
        input: "{\"probe\":true}\n",
        env: { ...process.env, HOME: home, PPOMI_ROOT: "", AI_GATEWAY_API_KEY: "", PPOMI_CHAT: "" },
      },
    );
    assert.equal(result.status, 0, result.stderr);
    const body = JSON.parse(result.stdout) as { configured: boolean };
    assert.equal(body.configured, false);
  } finally {
    rmSync(home, { recursive: true, force: true });
  }
});

const tauriDottedHost = join(dirname(hostFile), "..", "src-tauri", "..", "src", "host.ts");

function spawnHost(entry: string, args: readonly string[], env: NodeJS.ProcessEnv = {}, input?: string) {
  return spawnSync(process.execPath, ["--experimental-strip-types", entry, ...args], {
    encoding: "utf8",
    cwd: join(dirname(hostFile), ".."),
    input,
    env: {
      ...process.env,
      NODE_PATH: "/Applications/Grok.app/Contents/Resources/app/node_modules",
      NODE_OPTIONS: "",
      ...env,
    },
  });
}

test("host CLI --intent works with Tauri-style .. path and Grok NODE_PATH", () => {
  const result = spawnHost(tauriDottedHost, ["--intent", "지금 데이터 뭐 있어?"]);
  assert.equal(result.status, 0, result.stderr);
  const body = JSON.parse(result.stdout) as { status: string };
  assert.equal(body.status, "path_not_found");
});

test("host CLI --proxy-responses runs via symlink and dotted path", () => {
  const dir = mkdtempSync(join(tmpdir(), "ppomi-host-"));
  const link = join(dir, "host.ts");
  symlinkSync(hostFile, link);
  try {
    for (const entry of [tauriDottedHost, link]) {
      const result = spawnHost(entry, ["--proxy-responses"], { AI_GATEWAY_API_KEY: "", PPOMI_CHAT: "fixture" }, "{\"probe\":true}\n");
      assert.equal(result.status, 0, `${entry}\n${result.stderr}`);
      const body = JSON.parse(result.stdout) as { configured: boolean; fixture?: boolean };
      assert.equal(body.configured, true, entry);
      assert.equal(body.fixture, true, entry);
    }
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

const kbOpenIntent = "KB스타기업뱅킹 열어";

function assertKbColdStart(result: {
  status: string;
  pathId: string | null;
  note: string;
  body: { steps: readonly { stepId: string; status: string; note: string }[] } | null;
}): void {
  assert.equal(result.status, "needs_human");
  assert.equal(result.pathId, KB_STAR_BIZ_PATH_ID);
  assert.equal(result.body?.steps.find(step => step.stepId === "go-home")?.status, "ok");
  assert.equal(result.body?.steps.find(step => step.stepId === "open-kb")?.status, "ok");
  assert.equal(result.body?.steps.find(step => step.stepId === "human-login")?.status, "needs_human");
  const dumped = JSON.stringify(result);
  assert.doesNotMatch(dumped, new RegExp(fixtureAccount));
  assert.doesNotMatch(dumped, /1234567890/);
  assert.doesNotMatch(dumped, /\d{6}-\d{2}-\d{6}|\d{12,14}/);
}

test("Korean KB open intents choose the catalog path and stop at human login", async () => {
  for (const intent of [kbOpenIntent, "KB 사업자 홈", "path_cold_start"]) {
    const result = await runSpine({ intent, body: "macos", live: false });
    assertKbColdStart(result);
  }
});

test("host CLI exits 0 for KB스타기업뱅킹 열어 and is not path_not_found", () => {
  const result = spawnSync(
    process.execPath,
    ["--experimental-strip-types", hostFile, "--intent", kbOpenIntent],
    {
      encoding: "utf8",
      cwd: join(dirname(hostFile), ".."),
    },
  );
  assert.equal(result.status, 0, result.stderr);
  const body = JSON.parse(result.stdout) as {
    status: string;
    pathId: string | null;
    note: string;
    body: { steps: readonly { stepId: string; status: string; note: string }[] } | null;
  };
  assertKbColdStart(body);
});

test("bare 열어 still uses the home path", async () => {
  const result = await runSpine({ intent: "열어", body: "macos", live: false });
  assert.equal(result.status, "completed");
  assert.equal(result.pathId, "path-home-next");
});

test("live secrets off-darwin skips instead of failing", async () => {
  if (process.platform === "darwin" || process.platform === "win32") return;
  const result = await runSpine({ intent: ceoIntent, body: "macos", live: true });
  assert.equal(result.status, "completed");
  assert.match(result.note, /not darwin|no Keychain|Credential Manager/i);
  assert.doesNotMatch(JSON.stringify(result), new RegExp(fixtureAccount));
});
