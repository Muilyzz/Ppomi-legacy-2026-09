import assert from "node:assert/strict";
import { test } from "node:test";
import { allowGrant, denyGrant } from "../src/grant.ts";
import { orchestrate, PpomiBrain } from "../src/index.ts";
import {
  FixedPaths,
  MemoryLog,
  MockBody,
  MockSession,
  honestBody,
  identity,
  lookupPath,
  narrowGrant,
  payPath,
  sessionThatGrants,
} from "./fixtures.ts";

test("happy path chooses a path, checks grant, runs body, and records memory", async () => {
  const body = honestBody();
  const memory = new MemoryLog();
  const result = await orchestrate(
    {
      paths: new FixedPaths([lookupPath, payPath]),
      body,
      session: sessionThatGrants(lookupPath),
      memory,
    },
    { text: "잔액 보여줘", surface: "app" },
  );

  assert.equal(result.status, "completed");
  assert.equal(result.pathId, "path-balance");
  assert.deepEqual(result.grant, narrowGrant(lookupPath));
  assert.equal(result.body?.status, "completed");
  assert.deepEqual(result.body?.steps.map(step => step.status), ["ok"]);
  assert.equal(body.calls.length, 1);
  assert.equal(body.calls[0]?.grant.effects.includes("financial_submit"), false);
  assert.deepEqual(memory.events, [{
    kind: "run",
    pathId: "path-balance",
    status: "completed",
    note: "read-balance ok",
  }]);
});

test("grant deny never calls body and still records the stop", async () => {
  const body = honestBody();
  const memory = new MemoryLog();
  const result = await new PpomiBrain({
    paths: new FixedPaths([lookupPath, payPath]),
    body,
    session: new MockSession(identity, () => denyGrant("seat has lookup only for other paths")),
    memory,
  }).run({ text: "balance" });

  assert.equal(result.status, "grant_denied");
  assert.equal(result.pathId, "path-balance");
  assert.equal(result.grant, null);
  assert.equal(result.body, null);
  assert.equal(result.note, "seat has lookup only for other paths");
  assert.deepEqual(body.calls, []);
  assert.equal(memory.events[0]?.status, "grant_denied");
});

test("payment-like step stops as HITL and is not a completed financial submit", async () => {
  const body = honestBody();
  const result = await orchestrate(
    {
      paths: new FixedPaths([lookupPath, payPath]),
      body,
      session: sessionThatGrants(payPath),
    },
    { text: "공과금 납부" },
  );

  assert.equal(result.status, "needs_human");
  assert.equal(result.pathId, "path-pay");
  assert.equal(result.grant?.effects.includes("financial_submit"), false);
  assert.equal(result.body?.status, "stopped");
  assert.equal(result.body?.stopReason, "needs_human");
  assert.deepEqual(result.body?.steps.map(step => [step.stepId, step.status]), [
    ["read-bill", "ok"],
    ["fill-amount", "ok"],
    ["submit-pay", "needs_human"],
  ]);
  assert.match(result.note, /confirm_payment/);
  assert.equal(body.calls.length, 1);
});

test("brain rejects a body that claims financial_submit succeeded", async () => {
  const body = new MockBody(({ path }) => ({
    status: "completed",
    stopReason: null,
    steps: path.steps.map(step => ({
      stepId: step.id,
      effect: step.effect,
      status: "ok" as const,
      note: "auto submitted",
    })),
  }));

  const result = await orchestrate(
    {
      paths: new FixedPaths([payPath]),
      body,
      session: sessionThatGrants(payPath),
    },
    { text: "pay" },
  );

  assert.equal(result.status, "failed");
  assert.match(result.note, /financial_submit/);
  assert.equal(result.body?.steps.some(step => step.effect === "financial_submit" && step.status === "ok"), true);
});

test("a grant that includes financial_submit is refused before body runs", async () => {
  const body = honestBody();
  const result = await orchestrate(
    {
      paths: new FixedPaths([payPath]),
      body,
      session: new MockSession(identity, path => allowGrant({
        ...narrowGrant(path),
        effects: ["lookup", "input", "financial_submit"],
      })),
    },
    { text: "결제" },
  );

  assert.equal(result.status, "grant_denied");
  assert.equal(result.note, "financial_submit is never issued to the agent");
  assert.deepEqual(body.calls, []);
});
