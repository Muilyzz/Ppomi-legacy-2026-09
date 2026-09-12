import assert from "node:assert/strict";
import { createServer } from "node:http";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import {
  accountOpenCommand,
  clerkHandoffOrigin,
  listenForClerkHandoff,
  tokenFromHandoffBody,
} from "./clerk-handoff.ts";
import { parseClerkJwt, readStoredClerkSession } from "./clerk-session.ts";
import { liveClerkSession } from "./clerk-test-keys.ts";

async function freePort(): Promise<number> {
  return await new Promise((resolve, reject) => {
    const server = createServer();
    server.listen(0, "127.0.0.1", () => {
      const address = server.address();
      if (address === null || typeof address === "string") {
        server.close();
        reject(new Error("no port"));
        return;
      }
      const port = address.port;
      server.close(() => resolve(port));
    });
    server.once("error", reject);
  });
}

test("handoff body accepts clerkSession JSON, raw JWT, or ppomi:// fragment", () => {
  const token = liveClerkSession();
  assert.equal(tokenFromHandoffBody(JSON.stringify({ clerkSession: token })), token);
  assert.equal(tokenFromHandoffBody(token), token);
  assert.equal(tokenFromHandoffBody(`ppomi://clerk-session#${encodeURIComponent(token)}`), token);
  assert.equal(accountOpenCommand("http://127.0.0.1:3000/sign-in?from=shell", "darwin").cmd, "open");
  assert.equal(clerkHandoffOrigin(17382), "http://127.0.0.1:17382");
});

test("loopback POST writes ~/.ppomi/clerk-session and never echoes the JWT", async () => {
  const home = mkdtempSync(join(tmpdir(), "ppomi-handoff-"));
  const token = liveClerkSession();
  const opened: string[] = [];
  const port = await freePort();
  const pending = listenForClerkHandoff({
    env: { HOME: home, PPOMI_ACCOUNT_URL: "http://127.0.0.1:3000" },
    port,
    timeoutMs: 4000,
    opener: url => opened.push(url),
  });
  try {
    let health = { listening: false };
    for (let i = 0; i < 20; i++) {
      try {
        health = await (await fetch(`http://127.0.0.1:${port}/health`)).json() as { listening: boolean };
        if (health.listening) break;
      } catch {
        await new Promise(resolve => setTimeout(resolve, 50));
      }
    }
    assert.equal(health.listening, true);
    assert.deepEqual(opened, ["http://127.0.0.1:3000/sign-in?from=shell"]);
    const response = await fetch(`http://127.0.0.1:${port}/clerk-session`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ clerkSession: token }),
    });
    const body = await response.text();
    assert.equal(response.ok, true);
    assert.equal(JSON.parse(body).stored, true);
    assert.doesNotMatch(body, /user_2AbCdEfGhIjK|eyJ/);
    const result = await pending;
    assert.deepEqual(result, { stored: true, listening: false });
    assert.equal(readStoredClerkSession({ HOME: home }), token);
    assert.equal(parseClerkJwt(token) !== null, true);
  } finally {
    rmSync(home, { recursive: true, force: true });
  }
});

test("a second listener on a busy port still opens /sign-in?from=shell", async () => {
  const opened: string[] = [];
  const blocker = createServer((_req, res) => res.end("ok"));
  const port = await new Promise<number>((resolve, reject) => {
    blocker.listen(0, "127.0.0.1", () => {
      const address = blocker.address();
      if (address === null || typeof address === "string") {
        reject(new Error("no port"));
        return;
      }
      resolve(address.port);
    });
    blocker.once("error", reject);
  });
  try {
    const result = await listenForClerkHandoff({
      env: { PPOMI_ACCOUNT_URL: "http://127.0.0.1:3000" },
      port,
      timeoutMs: 500,
      opener: url => opened.push(url),
    });
    assert.deepEqual(result, { stored: false, listening: true, already: true });
    assert.deepEqual(opened, ["http://127.0.0.1:3000/sign-in?from=shell"]);
  } finally {
    await new Promise<void>(resolve => blocker.close(() => resolve()));
  }
});
