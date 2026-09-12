import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { test } from "node:test";
import { parseArgs, parseBodyKind, runSpine, secretsPath } from "./host.ts";

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

test("live secrets off-darwin skips instead of failing", async () => {
  if (process.platform === "darwin" || process.platform === "win32") return;
  const result = await runSpine({ intent: ceoIntent, body: "macos", live: true });
  assert.equal(result.status, "completed");
  assert.match(result.note, /not darwin|no Keychain|Credential Manager/i);
  assert.doesNotMatch(JSON.stringify(result), new RegExp(fixtureAccount));
});
