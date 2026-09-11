import assert from "node:assert/strict";
import { test } from "node:test";
import { InMemoryLog, MockAccount, MockBody, MockPath } from "../src/mocks.ts";
import { orchestrate } from "../src/orchestrate.ts";

test("browse intent selects sample-browse and completes on the mock body", async () => {
  const memory = new InMemoryLog();
  const result = await orchestrate({
    intent: "browse",
    path: new MockPath(),
    account: new MockAccount(),
    body: new MockBody(),
    memory,
  });
  assert.equal(result.status, "completed");
  assert.equal(result.pathId, "sample-browse");
  assert.equal(result.body, "mock");
  assert.equal(memory.list().length, 1);
});

test("certificate intent blocks payment/submit on the mock body", async () => {
  const result = await orchestrate({
    intent: "certificate",
    path: new MockPath(),
    account: new MockAccount(),
    body: new MockBody(),
    memory: new InMemoryLog(),
  });
  assert.equal(result.pathId, "joint-certificate-prepare");
  assert.equal(result.steps.some(step => step.outcome === "blocked_submit"), true);
  assert.equal(result.steps.some(step => step.outcome === "skipped_human"), true);
});

test("missing grant stops before the body runs", async () => {
  const result = await orchestrate({
    intent: "certificate",
    path: new MockPath(),
    account: new MockAccount(["ui.read"]),
    body: new MockBody(),
    memory: new InMemoryLog(),
  });
  assert.equal(result.status, "grant_denied");
  assert.equal(result.steps.length, 0);
});

test("unknown intent does not invent a path", async () => {
  const result = await orchestrate({
    intent: "transfer-all-money",
    path: new MockPath(),
    account: new MockAccount(),
    body: new MockBody(),
    memory: new InMemoryLog(),
  });
  assert.equal(result.status, "path_not_found");
});
