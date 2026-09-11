import assert from "node:assert/strict";
import { test } from "node:test";
import { allowGrant, denyGrant, inspectGrant } from "../src/grant.ts";
import { choosePath } from "../src/path.ts";
import { identity, lookupPath, narrowGrant, payPath } from "./fixtures.ts";

test("choosePath matches intent text and optional surface", () => {
  assert.equal(choosePath([lookupPath, payPath], { text: "잔액 조회" })?.id, "path-balance");
  assert.equal(choosePath([lookupPath, payPath], { text: "pay the bill" })?.id, "path-pay");
  assert.equal(choosePath([lookupPath], { text: "잔액", surface: "web" }), null);
  assert.equal(choosePath([lookupPath], { text: "   " }), null);
});

test("inspectGrant refuses financial_submit and missing effects", () => {
  const ok = inspectGrant(lookupPath, identity, allowGrant(narrowGrant(lookupPath)));
  assert.equal(ok.allowed, true);

  const widened = inspectGrant(
    payPath,
    identity,
    allowGrant({ ...narrowGrant(payPath), effects: ["lookup", "input", "financial_submit"] }),
  );
  assert.equal(widened.allowed, false);
  if (!widened.allowed) {
    assert.equal(widened.reason, "financial_submit is never issued to the agent");
  }

  const missing = inspectGrant(
    payPath,
    identity,
    allowGrant({ ...narrowGrant(payPath), effects: ["lookup"] }),
  );
  assert.equal(missing.allowed, false);
  if (!missing.allowed) {
    assert.equal(missing.reason, "missing effects: input");
  }

  assert.equal(inspectGrant(lookupPath, identity, denyGrant("seat closed")).allowed, false);
});
