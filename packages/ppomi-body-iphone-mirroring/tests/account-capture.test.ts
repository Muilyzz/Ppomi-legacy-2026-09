import assert from "node:assert/strict";
import { test } from "node:test";
import {
  AccountCapturePort,
  findAccountNumbers,
  maskAccountNumber,
  maskAccountText,
} from "../src/index.ts";

test("masks KB-shaped account numbers and finds exactly one", () => {
  assert.equal(maskAccountNumber("001234567890"), "****7890");
  assert.equal(maskAccountText("계좌 001-23-4567-890 상세"), "계좌 ****7890 상세");
  assert.deepEqual(findAccountNumbers(["잔액", "001234567890", "원"]), ["001234567890"]);
  assert.deepEqual(findAccountNumbers(["001234567890", "009876543210"]), ["001234567890", "009876543210"]);
});

test("capture port exposes mask only and hands raw once", () => {
  const port = new AccountCapturePort();
  const captured = port.ingest(["계좌번호", "001234567890"]);
  assert.deepEqual(captured, { masked: "****7890", last4: "7890" });
  assert.equal(JSON.stringify(captured).includes("001234567890"), false);
  assert.deepEqual(port.peekMasked(), { masked: "****7890", last4: "7890" });

  let handed = "";
  assert.equal(port.handoff(value => { handed = value; }), true);
  assert.equal(handed, "001234567890");
  assert.equal(port.peekMasked(), null);
  assert.equal(port.handoff(() => { throw new Error("must not run"); }), false);
});

test("two accounts on one screen are not captured", () => {
  const port = new AccountCapturePort();
  assert.equal(port.ingest(["001234567890", "009876543210"]), null);
  assert.equal(port.handoff(() => { throw new Error("must not run"); }), false);
});
