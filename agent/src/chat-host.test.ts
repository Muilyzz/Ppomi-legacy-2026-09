import { test } from "node:test";
import assert from "node:assert/strict";
import { NativeBridge, type Bootstrap } from "./bridge";
import { createNativeChatHost, type ChatHostEvents } from "./chat-host";

const bootstrap = (patch: Partial<Bootstrap> = {}): Bootstrap => ({
  platform: "macos", deviceLabel: "Synthetic Mac", configured: true, endpoint: "https://agent.example", tools: [], ...patch,
});

function eventsTarget() {
  const listeners = new Map<string, Set<() => void>>();
  return {
    addEventListener(type: string, listener: () => void) {
      if (!listeners.has(type)) listeners.set(type, new Set());
      listeners.get(type)!.add(listener);
    },
    removeEventListener(type: string, listener: () => void) { listeners.get(type)?.delete(listener); },
    dispatch(type: string) { for (const listener of listeners.get(type) ?? []) listener(); },
    count(type: string) { return listeners.get(type)?.size ?? 0; },
  };
}

function fixture() {
  const calls: { id: string; method: string; args: object }[] = [];
  const bridge = new NativeBridge(message => {
    const request = JSON.parse(message) as { id: string; method: string; args: object };
    calls.push(request);
    queueMicrotask(() => bridge.receive({ id: request.id, result: {} }));
  });
  const window = {
    ...eventsTarget(),
    ppomiVoiceStop: undefined as (() => void) | undefined,
    ppomiVoiceRefresh: undefined as (() => void) | undefined,
    ppomiAnswerCall: undefined as ((reason: string) => void) | undefined,
    ppomiIncomingCall: undefined as ((reason: string) => void) | undefined,
    ppomiToolProgress: undefined as ((event: { tool?: unknown; kind?: unknown; method?: unknown }) => void) | undefined,
    ppomiNotice: undefined as ((text: string) => void) | undefined,
  };
  const styles = new Map<string, string | null>();
  const document = {
    ...eventsTarget(), visibilityState: "visible",
    documentElement: { style: { setProperty: (name: string, value: string | null) => { styles.set(name, value); } }, dataset: {} as Record<string, string | undefined> },
  };
  const host = createNativeChatHost({ bridge, window, document });
  return { host, bridge, calls, window, document, styles };
}

function recorder() {
  const calls: [string, unknown?][] = [];
  const events: ChatHostEvents = {
    stop: () => calls.push(["stop"]), refresh: () => calls.push(["refresh"]),
    answerCall: reason => calls.push(["answer", reason]),
    incomingCall: reason => calls.push(["incoming", reason]),
    toolProgress: event => calls.push(["progress", event]),
    notice: text => calls.push(["notice", text]),
  };
  return { events, calls };
}

test("native chat host routes all native hooks and page lifecycle events", () => {
  const f = fixture(), r = recorder();
  const unsubscribe = f.host.subscribe(r.events);
  const progress = { tool: "screen_read", kind: "reading", method: "ocr" };
  f.window.ppomiAnswerCall!("승인 확인");
  f.window.ppomiIncomingCall!("");
  f.window.ppomiToolProgress!(progress);
  f.window.ppomiNotice!("확인할 일이 있습니다");
  f.window.ppomiVoiceStop!();
  f.window.ppomiVoiceRefresh!();
  f.window.dispatch("pagehide");
  f.window.dispatch("focus");
  f.document.dispatch("visibilitychange");
  assert.deepEqual(r.calls, [["answer", "승인 확인"], ["incoming", ""], ["progress", progress],
    ["notice", "확인할 일이 있습니다"], ["stop"], ["refresh"], ["stop"], ["refresh"], ["refresh"]]);
  assert.equal(r.calls[2][1], progress);
  unsubscribe();
});

test("native chat host leaves malformed hook values for the panel's existing checks", () => {
  const f = fixture(), r = recorder();
  const unsubscribe = f.host.subscribe(r.events);
  (f.window.ppomiAnswerCall as (reason?: unknown) => void)();
  (f.window.ppomiIncomingCall as (reason: unknown) => void)(123);
  (f.window.ppomiToolProgress as (event: unknown) => void)(null);
  (f.window.ppomiNotice as (text: unknown) => void)({ unexpected: true });
  assert.deepEqual(r.calls, [["answer", undefined], ["incoming", 123], ["progress", null], ["notice", { unexpected: true }]]);
  unsubscribe();
});

test("native chat host refreshes only when its document is not hidden", () => {
  const f = fixture(), r = recorder();
  const unsubscribe = f.host.subscribe(r.events);
  f.document.visibilityState = "hidden";
  f.window.ppomiVoiceRefresh!();
  f.window.dispatch("focus");
  f.document.dispatch("visibilitychange");
  assert.deepEqual(r.calls, []);
  f.window.dispatch("pagehide");
  assert.deepEqual(r.calls, [["stop"]]);
  f.document.visibilityState = "visible";
  f.document.dispatch("visibilitychange");
  assert.deepEqual(r.calls, [["stop"], ["refresh"]]);
  unsubscribe();
});

test("native chat host unsubscribes its hooks and listeners without stopping the panel", () => {
  const f = fixture(), r = recorder();
  const unsubscribe = f.host.subscribe(r.events);
  unsubscribe();
  unsubscribe();
  assert.deepEqual(r.calls, []);
  for (const key of ["ppomiVoiceStop", "ppomiVoiceRefresh", "ppomiAnswerCall", "ppomiIncomingCall", "ppomiToolProgress", "ppomiNotice"] as const) {
    assert.equal(f.window[key], undefined);
  }
  assert.equal(f.window.count("pagehide"), 0);
  assert.equal(f.window.count("focus"), 0);
  assert.equal(f.document.count("visibilitychange"), 0);
  f.window.dispatch("pagehide");
  f.window.dispatch("focus");
  f.document.dispatch("visibilitychange");
  assert.deepEqual(r.calls, []);
  assert.deepEqual(f.calls, []);
});

test("older native chat subscriptions cannot remove newer hooks or listeners", () => {
  const f = fixture(), first = recorder(), second = recorder();
  const unsubscribeFirst = f.host.subscribe(first.events);
  const unsubscribeSecond = f.host.subscribe(second.events);
  const externalNotice: (text: string) => void = () => { first.calls.push(["external"]); };
  f.window.ppomiNotice = externalNotice;
  unsubscribeFirst();
  f.window.ppomiVoiceStop!();
  f.window.ppomiAnswerCall!("new owner");
  f.window.dispatch("focus");
  f.document.dispatch("visibilitychange");
  assert.deepEqual(first.calls, []);
  assert.deepEqual(second.calls, [["stop"], ["answer", "new owner"], ["refresh"], ["refresh"]]);
  assert.equal(f.window.count("pagehide"), 1);
  unsubscribeSecond();
  assert.equal(f.window.ppomiNotice, externalNotice);
  f.window.ppomiNotice!("ignored");
  assert.deepEqual(first.calls, [["external"]]);
  assert.equal(f.window.count("pagehide"), 0);
});

test("native chat subscriptions have separate ownership even with reused callbacks", () => {
  const f = fixture(), r = recorder();
  const unsubscribeFirst = f.host.subscribe(r.events);
  const firstStop = f.window.ppomiVoiceStop;
  const unsubscribeSecond = f.host.subscribe(r.events);
  assert.notEqual(f.window.ppomiVoiceStop, firstStop);
  unsubscribeFirst();
  f.window.ppomiVoiceStop!();
  assert.deepEqual(r.calls, [["stop"]]);
  unsubscribeSecond();
});

test("native chat host applies the existing scale bounds and preserves omitted appearance", () => {
  const f = fixture();
  for (const [uiScale, expected] of [[undefined, "1"], [NaN, "1"], [Infinity, "1"], [0.1, "0.75"], [1.5, "1.5"], [10, "3"]] as const) {
    f.host.applyBootstrap(bootstrap({ uiScale }));
    assert.equal(f.styles.get("--ui-scale"), expected);
  }
  f.host.applyBootstrap(bootstrap({ dark: true }));
  assert.equal(f.document.documentElement.dataset.theme, "dark");
  f.host.applyBootstrap(bootstrap());
  assert.equal(f.document.documentElement.dataset.theme, "dark");
  f.host.applyBootstrap(bootstrap({ dark: false }));
  assert.equal(f.document.documentElement.dataset.theme, "light");
  assert.deepEqual(f.calls, []);
});

test("native chat host owns one readiness acknowledgement across subscriptions and refreshes", async () => {
  const f = fixture(), r = recorder();
  const ready = f.host.readiness;
  const compatible = bootstrap({ nativeBuild: 1, bridgeVersion: 1, webRelease: "synthetic-1", capabilities: ["agent.v1"] });
  ready.prepare(compatible);
  const unsubscribe = f.host.subscribe(r.events);
  await Promise.all([ready.commit(), ready.commit()]);
  assert.equal(await ready.wait(), compatible);
  unsubscribe();
  const unsubscribeAgain = f.host.subscribe(r.events);
  f.host.readiness.prepare({ ...compatible, configured: false });
  await f.host.readiness.commit();
  assert.equal(f.host.readiness, ready);
  assert.equal(f.host.bridge, f.bridge);
  assert.deepEqual(f.calls.map(({ method, args }) => ({ method, args })), [{ method: "updateReady", args: { bridgeVersion: 1 } }]);
  assert.equal(f.bridge.pendingCount, 0);
  unsubscribeAgain();
  const legacy = fixture();
  legacy.host.readiness.prepare(bootstrap());
  await legacy.host.readiness.commit();
  assert.deepEqual(legacy.calls, []);
});
