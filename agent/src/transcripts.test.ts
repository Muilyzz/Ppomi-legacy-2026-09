import { test } from "node:test";
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import type { UIMessage } from "ai";
import { completedTurns, mergeTranscriptMessages, projectTurn, redactTranscriptText, turnToMessage } from "./transcripts";

const message = (id: string, role: UIMessage["role"], parts: UIMessage["parts"]): UIMessage => ({ id, role, parts });

test("projectTurn keeps visible text and tool names and drops tool payloads", () => {
  const turn = projectTurn(message("11111111-1111-4111-8111-111111111111", "assistant", [
    { type: "text", text: "잔액은 62,000원입니다. Bearer sk-proj-secretvalue12" },
    { type: "reasoning", text: "계산 중", state: "done" },
    { type: "dynamic-tool", toolCallId: "t1", toolName: "screen_read", state: "output-available", input: { secret: "ocr" }, output: { text: "screen" } },
  ]));
  assert.deepEqual(turn, {
    id: "11111111-1111-4111-8111-111111111111",
    role: "assistant",
    parts: [
      { type: "text", text: "잔액은 62,000원입니다. [redacted]" },
      { type: "reasoning", text: "계산 중" },
      { type: "tool", name: "screen_read", state: "output-available" },
    ],
  });
  assert.equal(redactTranscriptText("sb_secret_abcdefghijklm"), "[redacted]");
});

test("hydrate and merge keep existing messages and append remote turns by id", () => {
  const local = [message("aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa", "user", [{ type: "text", text: "안녕" }])];
  const remote = [{ id: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa", role: "user" as const, parts: [{ type: "text" as const, text: "안녕" }] },
    { id: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb", role: "assistant" as const, parts: [{ type: "text" as const, text: "네" }] }];
  const merged = mergeTranscriptMessages(local, remote);
  assert.equal(merged.length, 2);
  assert.equal(merged[1]?.id, "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb");
  assert.equal(turnToMessage(remote[1]!).parts[0]?.type, "text");
});

test("useChat generateId is a UUID so transcript append matches hub/SQL", async () => {
  const source = await readFile(new URL("./chat-panel.tsx", import.meta.url), "utf8");
  assert.match(source, /generateId:\s*\(\)\s*=>\s*crypto\.randomUUID\(\)/);
});

test("projectTurn drops non-UUID ids so hub/SQL never see nanoid turn keys", () => {
  assert.equal(projectTurn(message("msg_local_nanoid", "user", [{ type: "text", text: "hi" }])), null);
  assert.equal(completedTurns([message("msg_local_nanoid", "user", [{ type: "text", text: "hi" }])], true).length, 0);
});

test("completedTurns wait until the local turn is ready", () => {
  const messages = [message("11111111-1111-4111-8111-111111111111", "user", [{ type: "text", text: "hi" }])];
  assert.deepEqual(completedTurns(messages, false), []);
  assert.equal(completedTurns(messages, true)[0]?.id, "11111111-1111-4111-8111-111111111111");
});
