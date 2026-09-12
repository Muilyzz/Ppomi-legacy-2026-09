import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { mkdtempSync, rmSync, symlinkSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { test } from "node:test";
import { proxyResponses } from "./gateway.ts";
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

test("gateway probe is configured only when a key or fixture is set", async () => {
  const off = await proxyResponses({ probe: true }, { env: {} });
  assert.deepEqual(off, { configured: false, fixture: false });
  const fixture = await proxyResponses({ probe: true }, { env: { PPOMI_CHAT: "fixture" } });
  assert.deepEqual(fixture, { configured: true, fixture: true });
  const live = await proxyResponses({ probe: true }, { env: { AI_GATEWAY_API_KEY: "k" } });
  assert.equal(live.configured, true);
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

test("host CLI --proxy-responses probe exits 0 without a key", () => {
  const result = spawnSync(
    process.execPath,
    ["--experimental-strip-types", hostFile, "--proxy-responses"],
    {
      encoding: "utf8",
      cwd: join(dirname(hostFile), ".."),
      input: "{\"probe\":true}\n",
      env: { ...process.env, AI_GATEWAY_API_KEY: "", PPOMI_CHAT: "" },
    },
  );
  assert.equal(result.status, 0, result.stderr);
  const body = JSON.parse(result.stdout) as { configured: boolean };
  assert.equal(body.configured, false);
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

test("host CLI --proxy-responses with unreadable stdin exits 1 and prints no JSON to fabricate from", () => {
  const result = spawnHost(hostFile, ["--proxy-responses"], { AI_GATEWAY_API_KEY: "", PPOMI_CHAT: "fixture" }, "not json\n");
  assert.equal(result.status, 1);
  assert.equal(result.stdout, "");
  assert.notEqual(result.stderr.trim(), "");
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
