import assert from "node:assert/strict";
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import {
  clerkSessionToken,
  decodeClerkSession,
  readStoredClerkSession,
  verifyClerkSession,
} from "./clerk-session.ts";

const NOW = Date.parse("2026-09-12T03:00:00Z");

function jwt(payload: Record<string, unknown>): string {
  const header = Buffer.from(JSON.stringify({ alg: "none", typ: "JWT" })).toString("base64url");
  const body = Buffer.from(JSON.stringify(payload)).toString("base64url");
  return `${header}.${body}.sig`;
}

function liveSession(overrides: Record<string, unknown> = {}): string {
  return jwt({
    sub: "user_2AbCdEfGhIjK",
    exp: Math.floor(NOW / 1000) + 3600,
    iss: "https://foo.clerk.accounts.dev",
    ...overrides,
  });
}

test("Clerk session JWT needs user_ sub, https iss, and a future exp", () => {
  const token = liveSession();
  assert.deepEqual(decodeClerkSession(token), {
    sub: "user_2AbCdEfGhIjK",
    exp: Math.floor(NOW / 1000) + 3600,
    iss: "https://foo.clerk.accounts.dev",
  });
  assert.equal(verifyClerkSession(token, NOW), true);
  assert.equal(verifyClerkSession(liveSession({ sub: "550e8400-e29b-41d4-a716-446655440000" }), NOW), false);
  assert.equal(verifyClerkSession(liveSession({ exp: Math.floor(NOW / 1000) - 1 }), NOW), false);
  assert.equal(verifyClerkSession(liveSession({ iss: "http://foo.clerk.accounts.dev" }), NOW), false);
  assert.equal(verifyClerkSession("not-a-jwt", NOW), false);
  assert.equal(verifyClerkSession(undefined, NOW), false);
});

test("request clerkSession wins over stored files", () => {
  const home = mkdtempSync(join(tmpdir(), "ppomi-clerk-"));
  try {
    mkdirSync(join(home, ".ppomi"), { mode: 0o700 });
    writeFileSync(join(home, ".ppomi", "clerk-session"), liveSession({ sub: "user_2FileSessionX" }), { mode: 0o600 });
    const bodyToken = liveSession({ sub: "user_2BodySessionXX" });
    assert.equal(clerkSessionToken({ clerkSession: bodyToken }, { HOME: home }), bodyToken);
    assert.equal(clerkSessionToken({ probe: true }, { HOME: home, CLERK_SESSION: liveSession({ sub: "user_2EnvSessionXXX" }) })?.includes("."), true);
    assert.equal(decodeClerkSession(readStoredClerkSession({ HOME: home }) ?? "")?.sub, "user_2FileSessionX");
  } finally {
    rmSync(home, { recursive: true, force: true });
  }
});

test("~/.ppomi/.env CLERK_SESSION is read when the session file is absent", () => {
  const home = mkdtempSync(join(tmpdir(), "ppomi-clerk-env-"));
  try {
    const token = liveSession();
    mkdirSync(join(home, ".ppomi"), { mode: 0o700 });
    writeFileSync(join(home, ".ppomi", ".env"), `AI_GATEWAY_API_KEY=file-secret-key\nCLERK_SESSION=${token}\n`, { mode: 0o600 });
    assert.equal(clerkSessionToken({ probe: true }, { HOME: home }), token);
    assert.equal(verifyClerkSession(clerkSessionToken({ probe: true }, { HOME: home }), NOW), true);
  } finally {
    rmSync(home, { recursive: true, force: true });
  }
});
