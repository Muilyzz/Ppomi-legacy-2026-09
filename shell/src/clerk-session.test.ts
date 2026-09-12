import assert from "node:assert/strict";
import { mkdirSync, mkdtempSync, rmSync, statSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import {
  clerkAccountSignInUrl,
  clerkSessionToken,
  clerkVerifyConfig,
  parseClerkJwt,
  readStoredClerkSession,
  secretFileOk,
  tokenFromClerkHandoffUrl,
  verifyClerkSession,
  writeStoredClerkSession,
} from "./clerk-session.ts";
import {
  CLERK_TEST_AZP,
  CLERK_TEST_ISSUER,
  CLERK_TEST_NOW,
  clerkTestEnv,
  clerkTestJwk,
  liveClerkSession,
  unsignedClerkSession,
} from "./clerk-test-keys.ts";

test("Clerk JWKS verify needs RS256/ES256, allowlisted iss, and aud/azp", async () => {
  const token = liveClerkSession({}, CLERK_TEST_NOW);
  assert.equal(parseClerkJwt(token)?.claims.sub, "user_2AbCdEfGhIjK");
  assert.equal(await verifyClerkSession(token, clerkTestEnv, { nowMs: CLERK_TEST_NOW }), true);
  assert.equal(await verifyClerkSession(unsignedClerkSession({}, "none", CLERK_TEST_NOW), clerkTestEnv, { nowMs: CLERK_TEST_NOW }), false);
  assert.equal(await verifyClerkSession(liveClerkSession({ iss: "https://evil.example" }, CLERK_TEST_NOW), clerkTestEnv, { nowMs: CLERK_TEST_NOW }), false);
  assert.equal(await verifyClerkSession(liveClerkSession({ iss: "http://foo.clerk.accounts.dev" }, CLERK_TEST_NOW), clerkTestEnv, { nowMs: CLERK_TEST_NOW }), false);
  assert.equal(await verifyClerkSession(liveClerkSession({ azp: "https://evil.example" }, CLERK_TEST_NOW), clerkTestEnv, { nowMs: CLERK_TEST_NOW }), false);
  assert.equal(await verifyClerkSession(liveClerkSession({ sub: "550e8400-e29b-41d4-a716-446655440000" }, CLERK_TEST_NOW), clerkTestEnv, { nowMs: CLERK_TEST_NOW }), false);
  assert.equal(await verifyClerkSession(liveClerkSession({ exp: Math.floor(CLERK_TEST_NOW / 1000) - 1 }, CLERK_TEST_NOW), clerkTestEnv, { nowMs: CLERK_TEST_NOW }), false);
  assert.equal(await verifyClerkSession("not-a-jwt", clerkTestEnv, { nowMs: CLERK_TEST_NOW }), false);
  assert.equal(await verifyClerkSession(undefined, clerkTestEnv, { nowMs: CLERK_TEST_NOW }), false);
  assert.equal(await verifyClerkSession(token, { CLERK_ISSUER: CLERK_TEST_ISSUER }, { nowMs: CLERK_TEST_NOW }), false);
});

test("alg:none and missing JWKS config never verify", async () => {
  assert.equal(clerkVerifyConfig({}), null);
  assert.equal(clerkVerifyConfig({ CLERK_ISSUER: "http://foo.clerk.accounts.dev", CLERK_AUTHORIZED_PARTIES: CLERK_TEST_AZP }), null);
  assert.equal(await verifyClerkSession(unsignedClerkSession({}, "none", CLERK_TEST_NOW), clerkTestEnv, { nowMs: CLERK_TEST_NOW }), false);
  assert.equal(await verifyClerkSession(liveClerkSession({}, CLERK_TEST_NOW), {}, { nowMs: CLERK_TEST_NOW }), false);
});

test("JWKS fetch uses the allowlisted issuer, never token.iss", async () => {
  const env = { CLERK_ISSUER: CLERK_TEST_ISSUER, CLERK_AUTHORIZED_PARTIES: CLERK_TEST_AZP };
  const seen: string[] = [];
  const fetchFn: typeof fetch = async url => {
    seen.push(String(url));
    return new Response(JSON.stringify({ keys: [clerkTestJwk] }), { status: 200, headers: { "content-type": "application/json" } });
  };
  assert.equal(await verifyClerkSession(liveClerkSession({}, CLERK_TEST_NOW), env, { nowMs: CLERK_TEST_NOW, fetch: fetchFn }), true);
  assert.deepEqual(seen, [`${CLERK_TEST_ISSUER}/.well-known/jwks.json`]);
  seen.length = 0;
  assert.equal(await verifyClerkSession(liveClerkSession({ iss: "https://evil.example" }, CLERK_TEST_NOW), env, { nowMs: CLERK_TEST_NOW, fetch: fetchFn }), false);
  assert.deepEqual(seen, []);
});

test("request clerkSession wins over stored files", () => {
  const home = mkdtempSync(join(tmpdir(), "ppomi-clerk-"));
  try {
    mkdirSync(join(home, ".ppomi"), { mode: 0o700 });
    writeFileSync(join(home, ".ppomi", "clerk-session"), liveClerkSession({ sub: "user_2FileSessionX" }), { mode: 0o600 });
    const bodyToken = liveClerkSession({ sub: "user_2BodySessionXX" });
    assert.equal(clerkSessionToken({ clerkSession: bodyToken }, { HOME: home }), bodyToken);
    assert.equal(clerkSessionToken({ probe: true }, { HOME: home, CLERK_SESSION: liveClerkSession({ sub: "user_2EnvSessionXXX" }) })?.includes("."), true);
    assert.equal(parseClerkJwt(readStoredClerkSession({ HOME: home }) ?? "")?.claims.sub, "user_2FileSessionX");
  } finally {
    rmSync(home, { recursive: true, force: true });
  }
});

test("~/.ppomi/.env CLERK_SESSION is read when the session file is absent", async () => {
  const home = mkdtempSync(join(tmpdir(), "ppomi-clerk-env-"));
  try {
    const token = liveClerkSession();
    mkdirSync(join(home, ".ppomi"), { mode: 0o700 });
    writeFileSync(join(home, ".ppomi", ".env"), `AI_GATEWAY_API_KEY=file-secret-key\nCLERK_SESSION=${token}\n`, { mode: 0o600 });
    assert.equal(secretFileOk(join(home, ".ppomi", ".env")), true);
    assert.equal(clerkSessionToken({ probe: true }, { HOME: home }), token);
    assert.equal(await verifyClerkSession(clerkSessionToken({ probe: true }, { HOME: home }), clerkTestEnv), true);
  } finally {
    rmSync(home, { recursive: true, force: true });
  }
});

test("group-readable clerk-session is refused", () => {
  const home = mkdtempSync(join(tmpdir(), "ppomi-clerk-mode-"));
  try {
    mkdirSync(join(home, ".ppomi"), { mode: 0o700 });
    const path = join(home, ".ppomi", "clerk-session");
    writeFileSync(path, liveClerkSession(), { mode: 0o644 });
    assert.equal(secretFileOk(path), false);
    assert.equal(readStoredClerkSession({ HOME: home }), undefined);
  } finally {
    rmSync(home, { recursive: true, force: true });
  }
});

test("writeStoredClerkSession keeps a 0600 JWT file the host already reads", () => {
  const home = mkdtempSync(join(tmpdir(), "ppomi-clerk-write-"));
  try {
    const token = liveClerkSession();
    const file = writeStoredClerkSession(token, { HOME: home });
    assert.equal(file, join(home, ".ppomi", "clerk-session"));
    assert.equal(readStoredClerkSession({ HOME: home }), token);
    assert.equal(statSync(file).mode & 0o777, 0o600);
    assert.throws(() => writeStoredClerkSession("not-a-jwt", { HOME: home }), /invalid clerk session/);
    assert.throws(() => writeStoredClerkSession(unsignedClerkSession(), { HOME: home }), /invalid clerk session/);
  } finally {
    rmSync(home, { recursive: true, force: true });
  }
});

test("ppomi://clerk-session fragment and local /sign-in?from=shell are the handoff URLs", () => {
  const token = liveClerkSession();
  assert.equal(tokenFromClerkHandoffUrl(`ppomi://clerk-session#${encodeURIComponent(token)}`), token);
  assert.equal(tokenFromClerkHandoffUrl(`ppomi://clerk-session?clerkSession=${encodeURIComponent(token)}`), token);
  assert.equal(tokenFromClerkHandoffUrl("https://example.test/#nope"), undefined);
  assert.equal(tokenFromClerkHandoffUrl("ppomi://other#x"), undefined);
  assert.equal(
    clerkAccountSignInUrl({ PPOMI_ACCOUNT_URL: "https://account.example/" }),
    "https://account.example/sign-in?from=shell",
  );
  const home = mkdtempSync(join(tmpdir(), "ppomi-account-url-"));
  try {
    mkdirSync(join(home, ".ppomi"), { mode: 0o700 });
    writeFileSync(join(home, ".ppomi", ".env"), "PPOMI_ACCOUNT_URL=http://127.0.0.1:3456\n", { mode: 0o600 });
    assert.equal(clerkAccountSignInUrl({ HOME: home }), "http://127.0.0.1:3456/sign-in?from=shell");
  } finally {
    rmSync(home, { recursive: true, force: true });
  }
});
