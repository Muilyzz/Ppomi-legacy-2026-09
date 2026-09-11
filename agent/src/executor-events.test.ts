import { test } from "node:test";
import assert from "node:assert/strict";
import { receiveExecutorNotification } from "./executor-events";

test("native notices remain data and unknown commands are ignored", () => {
  const notices: string[] = [];
  let stops = 0;
  const hooks = { ppomiNotice: (text: string) => notices.push(text), ppomiVoiceStop: () => { stops++; } };
  receiveExecutorNotification({ event: "notice", payload: { text: "<script>unsafe()</script>" } }, hooks);
  receiveExecutorNotification({ event: "evaluateJavascript", payload: "unsafe()" }, hooks);
  receiveExecutorNotification({ event: "stop", payload: {} }, hooks);
  assert.deepEqual(notices, ["<script>unsafe()</script>"]);
  assert.equal(stops, 1);
});

test("a cleared incoming call is delivered and malformed messages cannot become notices", () => {
  const reasons: string[] = [];
  const hooks = { ppomiIncomingCall: (reason: string) => reasons.push(reason), ppomiNotice: () => assert.fail("invalid notice") };
  receiveExecutorNotification({ event: "incomingCall", payload: { reason: "" } }, hooks);
  receiveExecutorNotification({ event: "notice", payload: 42 }, hooks);
  assert.deepEqual(reasons, [""]);
});
