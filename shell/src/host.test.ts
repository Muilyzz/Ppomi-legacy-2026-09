import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { mkdtempSync, rmSync, symlinkSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { test } from "node:test";
import { MacosAdapterError, type MacScreenNode } from "../../packages/ppomi-body-macos/src/index.ts";
import { proxyResponses } from "./gateway.ts";
import { homePath, parseArgs, parseBodyKind, runLiveMacos, runSpine, secretsPath, type LiveMacTools, type RunCapture } from "./host.ts";

const hostFile = join(dirname(fileURLToPath(import.meta.url)), "host.ts");

const EXAMPLE_NODES: readonly MacScreenNode[] = [
  { id: "n0", text: "Example Domain", clickable: false, editable: false },
  { id: "n1", text: "More information...", clickable: true, editable: false },
];

interface FakeLiveOptions {
  readonly trusted?: boolean;
  readonly nodes?: readonly MacScreenNode[];
  readonly openError?: Error;
}

function fakeLiveTools(options: FakeLiveOptions = {}): LiveMacTools & { readonly taps: string[] } {
  const nodes = options.nodes ?? EXAMPLE_NODES;
  const taps: string[] = [];
  return {
    app: "Safari",
    taps,
    trusted: () => options.trusted ?? true,
    browser_open: () => {
      if (options.openError !== undefined) throw options.openError;
      return { opened: true, app: "Safari" };
    },
    screen_read: () => ({ snapshotId: "fake-1", appLabel: "Safari", nodes, truncated: false }),
    ui_tap: ({ nodeId }) => {
      taps.push(nodeId);
      return { invoked: true };
    },
    ui_type: () => ({ typed: true }),
  };
}

test("macos fixture 1-step reaches ppomi-body-macos through brain and keeps the core RunResult", async () => {
  const result = await runSpine({ intent: "다음", body: "macos", live: false });
  assert.equal(result.status, "completed");
  assert.equal(result.pathId, "path-home-next");
  assert.equal(result.bodyKind, "macos");
  assert.equal(result.body?.status, "completed");
  assert.equal(result.body?.steps[0]?.status, "ok");
  assert.equal(result.run?.status, "completed");
  assert.equal(result.run?.stepResults[0]?.driver, "os-macos");
  assert.equal(result.run?.stepResults[0]?.attempt, "executed");
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

test("live macos off-darwin stops as needs_human, never completed", async () => {
  if (process.platform === "darwin") return;
  const result = await runSpine({ intent: "다음", body: "macos", live: true });
  assert.equal(result.status, "needs_human");
  assert.equal(result.body?.status, "stopped");
  assert.equal(result.body?.stopReason, "needs_human");
  assert.equal(result.body?.steps[0]?.status, "needs_human");
  assert.equal(result.run, null);
  assert.equal(result.live, true);
  assert.match(result.note, /needs a Mac/);
});

test("live windows / android are not wired through the shell: stopped/failed, fixture not run", async () => {
  const windows = await runSpine({ intent: "다음", body: "windows", live: true });
  assert.equal(windows.status, "failed");
  assert.equal(windows.body?.status, "stopped");
  assert.equal(windows.body?.stopReason, "failed");
  assert.equal(windows.run, null);
  assert.match(windows.note, /MZZ-55b/);
  const android = await runSpine({ intent: "다음", body: "android", live: true });
  assert.equal(android.status, "failed");
  assert.equal(android.run, null);
  assert.match(android.note, /MZZ-55c/);
});

test("live macos: Accessibility denied is grant_denied and nothing is opened or tapped", async () => {
  const tools = fakeLiveTools({ trusted: false });
  const capture: RunCapture = { run: null };
  const result = await runLiveMacos(homePath, tools, capture);
  assert.equal(result.status, "stopped");
  assert.equal(result.stopReason, "grant_denied");
  assert.equal(result.steps[0]?.status, "grant_denied");
  assert.match(result.steps[0]?.note ?? "", /Accessibility denied/);
  assert.equal(capture.run, null);
  assert.deepEqual(tools.taps, []);
});

test("live macos: front window without the example.com link is needs_human, no other click", async () => {
  const tools = fakeLiveTools({
    nodes: [
      { id: "n0", text: "Some other page", clickable: false, editable: false },
      { id: "n1", text: "Buy now", clickable: true, editable: false },
    ],
  });
  const capture: RunCapture = { run: null };
  const result = await runLiveMacos(homePath, tools, capture);
  assert.equal(result.status, "stopped");
  assert.equal(result.stopReason, "needs_human");
  assert.match(result.steps[0]?.note ?? "", /More information/);
  assert.equal(capture.run, null);
  assert.deepEqual(tools.taps, []);
});

test("live macos: a thrown tool error is failed with its code, and URLs in the message are redacted", async () => {
  const tools = fakeLiveTools({
    openError: new MacosAdapterError("accessibility", "Not authorized https://example.com/?session=abc123 (-1743)"),
  });
  const capture: RunCapture = { run: null };
  const result = await runLiveMacos(homePath, tools, capture);
  assert.equal(result.status, "stopped");
  assert.equal(result.stopReason, "failed");
  assert.equal(result.steps[0]?.status, "failed");
  assert.match(result.steps[0]?.note ?? "", /accessibility: Not authorized https:\/\/example\.com\//);
  assert.doesNotMatch(result.steps[0]?.note ?? "", /session=abc123/);
  assert.equal(capture.run, null);
  assert.deepEqual(tools.taps, []);
});

test("live macos: completed only when Runtime completed the gated click", async () => {
  const tools = fakeLiveTools();
  const capture: RunCapture = { run: null };
  const result = await runLiveMacos(homePath, tools, capture);
  assert.equal(result.status, "completed");
  assert.equal(result.stopReason, null);
  assert.equal(result.steps[0]?.status, "ok");
  assert.equal(capture.run?.status, "completed");
  assert.equal(capture.run?.stepResults[0]?.driver, "os-macos");
  assert.equal(capture.run?.stepResults[0]?.attempt, "executed");
  assert.deepEqual(capture.run?.stepResults[0]?.target, { kind: "accessibility", name: "More information..." });
  assert.deepEqual(tools.taps, ["n1"]);
});

test("parseArgs reads intent and body; live needs both --live and PPOMI_BODY_LIVE=1", () => {
  assert.equal(parseBodyKind(undefined), "macos");
  assert.deepEqual(parseArgs(["열어", "--body", "windows", "--live"], { PPOMI_BODY_LIVE: "1" }), {
    intent: "열어",
    body: "windows",
    live: true,
  });
  assert.deepEqual(parseArgs(["열어"], { PPOMI_BODY_LIVE: "1" }), { intent: "열어", body: "macos", live: false });
  assert.deepEqual(parseArgs(["열어"], { PPOMI_BODY_LIVE: "1", PPOMI_BODY_AX: "1" }), { intent: "열어", body: "macos", live: false });
  assert.throws(() => parseArgs(["--live"], {}), /PPOMI_BODY_LIVE=1/);
  assert.throws(() => parseArgs(["--live"], { PPOMI_BODY_AX: "1" }), /PPOMI_BODY_LIVE=1/);
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
  for (const intent of [ceoIntent, "KB 계좌번호", "사업자 계좌 알려줘", "account number", "통장번호"]) {
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

test("live secrets off-darwin stops as needs_human with no read behind it", async () => {
  if (process.platform === "darwin" || process.platform === "win32") return;
  const result = await runSpine({ intent: ceoIntent, body: "macos", live: true });
  assert.equal(result.status, "needs_human");
  assert.equal(result.body?.status, "stopped");
  assert.equal(result.run, null);
  assert.match(result.note, /no Keychain \/ Credential Manager here/i);
  assert.doesNotMatch(JSON.stringify(result), new RegExp(fixtureAccount));
});
