import assert from "node:assert/strict";
import { test } from "node:test";
import {
  AccountCapturePort,
  findAccountNumbers,
  isAccountText,
  maskAccountNumber,
  maskAccountRows,
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

test("masks the separators OCR renders and any account-length digit run", () => {
  assert.equal(maskAccountText("계좌번호 001234–56–789012"), "계좌번호 ****9012"); // en dash
  assert.equal(maskAccountText("계좌번호 001234—56—789012"), "계좌번호 ****9012"); // em dash
  assert.equal(maskAccountText("계좌번호 001234－56－789012"), "계좌번호 ****9012"); // fullwidth
  assert.equal(maskAccountText("계좌번호 001234 - 56 - 789012"), "계좌번호 ****9012"); // spaced dash
  assert.equal(maskAccountText("계좌번호 001234 56 789012"), "계좌번호 ****9012"); // spaces
  assert.equal(maskAccountText("계좌번호 001234\u00A056\u00A0789012"), "계좌번호 ****9012"); // NBSP
  assert.equal(maskAccountText("123-456-789012"), "****9012"); // 3-3-6, another bank
  assert.equal(maskAccountText("1234-5678-9012"), "****9012"); // 4-4-4
  assert.equal(maskAccountText("0123456789"), "****6789"); // 10 digits
  assert.equal(maskAccountText("1234-5678-9012-3456"), "****3456"); // 16-digit card
  for (const kept of ["2026-09-11", "1,234,567원", "12:34", "123456789", "20260911", "15000"]) {
    assert.equal(maskAccountText(kept), kept);
    assert.equal(isAccountText(kept), false);
  }
  assert.equal(isAccountText("010-1234-5678"), true);
});

test("maskAccountRows masks a run split over the boxes of one line", () => {
  assert.deepEqual(
    maskAccountRows(["계좌번호", "001234-56", "789012", "원"]),
    ["계좌번호", "****", "****9012", "원"],
  );
  assert.deepEqual(maskAccountRows(["A 001234567890 B", "잔액"]), ["A ****7890 B", "잔액"]);
  assert.deepEqual(
    maskAccountRows(["001234567890", "009876543210"]),
    ["****7890", "****3210"],
  );
  assert.deepEqual(maskAccountRows(["계좌조회", "이체내역"]), ["계좌조회", "이체내역"]);
});

test("capture keeps KB shapes and never absorbs a neighbouring digit token", () => {
  assert.deepEqual(findAccountNumbers(["11 001234-56-789012"]), ["00123456789012"]);
  assert.deepEqual(findAccountNumbers(["2026 001234567890"]), ["001234567890"]);
  assert.deepEqual(findAccountNumbers(["001234 56 789012"]), ["00123456789012"]);
  assert.deepEqual(findAccountNumbers(["001234–56–789012"]), ["00123456789012"]);
  assert.deepEqual(findAccountNumbers(["010-1234-5678", "123-456-789012"]), []);
  assert.equal(isAccountText("123-456-789012"), true);
});
