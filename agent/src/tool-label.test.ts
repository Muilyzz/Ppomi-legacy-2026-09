import { test } from "node:test";
import assert from "node:assert/strict";
import { toolLabel } from "./tool-label";

test("tool rows say what ran and how the screen was observed", () => {
  assert.equal(toolLabel("phone_screen"), "iPhone 화면 읽기 · OCR");
  assert.equal(toolLabel("windows_click"), "Windows 누르기 · OCR");
  assert.equal(toolLabel("android_tap"), "Android 누르기 · DOM");
  assert.equal(toolLabel("screen_inspect"), "화면 관찰 · VLM(유료)");
  assert.equal(toolLabel("profile_fill"), "기본정보 입력 · 비공개 OCR");
  assert.equal(toolLabel("bank_profile_capture"), "은행정보 수집 · 비공개 OCR");
  assert.equal(toolLabel("ui_tap"), "화면 누르기 · DOM");
  assert.equal(toolLabel("read_playbook"), "절차 읽기");
  assert.equal(toolLabel("path_cold_start"), "Home 후 KB 열기");
  assert.equal(toolLabel("phone_frobnicate"), "iPhone frobnicate · OCR");
  assert.equal(toolLabel("something_else"), "도구 실행");
});
