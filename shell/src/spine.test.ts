import assert from "node:assert/strict";
import { test } from "node:test";
import { linesFromSpine, previewSpine, textFromSpine, type SpineView } from "./spine.ts";

const missing: SpineView = {
  status: "path_not_found",
  pathId: null,
  note: "no path matched the intent",
  bodyKind: "macos",
  live: false,
  hook: "unused",
  body: null,
};

const done: SpineView = {
  status: "completed",
  pathId: "path-home-next",
  note: "clicked Next",
  bodyKind: "macos",
  live: false,
  hook: "PPOMI_BODY_LIVE=1 npm --prefix shell run host",
  body: { status: "completed", steps: [{ stepId: "open-next", status: "ok", note: "clicked Next" }] },
};

test("path_not_found is a Korean bubble, not a raw status dump", () => {
  assert.equal(textFromSpine(missing), "그 일에 맞는 경로가 아직 없습니다.");
  assert.deepEqual(linesFromSpine(missing), [
    { kind: "bubble", role: "assistant", text: "그 일에 맞는 경로가 아직 없습니다." },
  ]);
});

test("completed path becomes an AI-elements tool card plus a short reply", () => {
  const lines = linesFromSpine(done);
  assert.equal(lines[0]?.kind, "tool");
  assert.equal(lines[1]?.kind, "bubble");
  if (lines[0]?.kind !== "tool" || lines[1]?.kind !== "bubble") return;
  assert.equal(lines[0].tool.name, "run_path");
  assert.equal(lines[0].tool.label, "path-home-next");
  assert.equal(lines[0].tool.state, "output-available");
  assert.equal(lines[1].text, "다음을 눌렀습니다.");
  assert.doesNotMatch(lines[1].text, /status|hook|node host/i);
});

test("preview spine matches host intents", () => {
  assert.equal(previewSpine("다음").status, "completed");
  assert.equal(previewSpine("no-such-path").status, "path_not_found");
});
