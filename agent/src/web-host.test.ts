import { test } from "node:test";
import assert from "node:assert/strict";
import { NativeBridgeError, validateBootstrap } from "./bridge";
import type { ChatHostEvents } from "./chat-host";
import { createWebBridge, createWebChatHost, webBootstrap, webEndpoint, type WebHostSource, type WebHostState } from "./web-host";

const ALICE = { id: "11111111-1111-4111-8111-111111111111", name: "Alice fixture", email: "alice@example.test" };
const DEVICE = "dddddddd-1111-4111-8111-111111111111";
const TOKEN = "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiJhbGljZSJ9.c2lnbmF0dXJl";

function source(initial: Partial<WebHostState> = {}) {
  let state: WebHostState = { account: null, deviceID: null, notice: "", noticeIsError: false, ...initial };
  const listeners = new Set<() => void>();
  const calls: string[] = [];
  let token: Promise<string> = Promise.resolve(TOKEN);
  const value: WebHostSource & { set(patch: Partial<WebHostState>): void; calls: string[]; failToken(): void; listeners: Set<() => void> } = {
    endpoint: "https://agent.example",
    getState: () => state,
    subscribe(listener) { listeners.add(listener); return () => listeners.delete(listener); },
    getAccessToken: () => { calls.push("token"); return token; },
    signIn: async () => { calls.push("signIn"); },
    signOut: async () => { calls.push("signOut"); },
    set(patch) { state = { ...state, ...patch }; for (const listener of listeners) listener(); },
    failToken() { token = Promise.reject(new Error("signed out")); token.catch(() => {}); },
    calls, listeners,
  };
  return value;
}

type Call = { url: string; init: RequestInit; headers: Headers };
function transport(respond: (call: Call) => Response | Promise<Response>) {
  const calls: Call[] = [];
  const fetcher = (async (url: string | URL | Request, init?: RequestInit) => {
    const call = { url: String(url), init: init ?? {}, headers: new Headers(init?.headers) };
    calls.push(call);
    return respond(call);
  }) as typeof fetch;
  return { calls, fetcher };
}

const rejects = (promise: Promise<unknown>, code: string) => assert.rejects(promise, (error: unknown) => error instanceof NativeBridgeError && error.code === code);

test("web bootstrap is configured only for a signed-in account whose browser device was confirmed", () => {
  const s = source();
  const signedOut = webBootstrap(s);
  assert.equal(signedOut.platform, "web");
  assert.equal(signedOut.configured, false);
  assert.deepEqual(signedOut.tools, []);
  assert.equal(signedOut.voiceSupported, false);
  assert.equal(signedOut.bankProfileSupported, false);
  assert.equal(signedOut.authentication?.signedIn, false);
  assert.equal(signedOut.authentication?.googleSignIn, true);
  assert.equal(signedOut.executor?.googleSignIn, true);
  assert.equal("displayName" in (signedOut.authentication ?? {}), false);
  s.set({ account: ALICE });
  assert.equal(webBootstrap(s).configured, false, "a registered device is required before any server request");
  assert.equal(webBootstrap(s).authentication?.signedIn, true);
  assert.equal(webBootstrap(s).authentication?.displayName, "Alice fixture");
  s.set({ deviceID: DEVICE });
  const ready = webBootstrap(s);
  assert.equal(ready.configured, true);
  assert.equal(ready.endpoint, "https://agent.example");
  assert.equal(validateBootstrap(ready), ready, "the shared validator accepts the browser bootstrap");
  s.set({ account: { ...ALICE, name: null } });
  assert.equal(webBootstrap(s).authentication?.displayName, "alice@example.test");
  assert.equal(ready.nativeBuild, undefined, "no family-update metadata: the web is always the served release");
});

test("web endpoint accepts only a bare https origin and path", () => {
  assert.equal(webEndpoint("https://ppomi-agent.vercel.app"), "https://ppomi-agent.vercel.app");
  assert.equal(webEndpoint("https://agent.example/base/"), "https://agent.example/base");
  for (const bad of ["http://agent.example", "https://user:pw@agent.example", "https://agent.example/?x=1", "https://agent.example/#f",
    "https://agent.example/a/../b", "https://agent.example/%2e%2e", "not a url", "https://agent.example/ path"]) {
    assert.throws(() => webEndpoint(bad), `${bad} is refused`);
  }
  assert.throws(() => createWebBridge({ ...source(), endpoint: "http://agent.example" }));
});

test("web bridge relays the two conversation paths with the account token and device header", async () => {
  const s = source({ account: ALICE, deviceID: DEVICE.toUpperCase() });
  const t = transport(call => Response.json(call.url.endsWith("/v1/session") ? { model: "synthetic-model" } : { id: "resp_1", output: [] }));
  const bridge = createWebBridge(s, { fetch: t.fetcher });
  assert.deepEqual(await bridge.call("request", { path: "/v1/session", body: { mode: "text" } }), { model: "synthetic-model" });
  assert.deepEqual(await bridge.call("request", { path: "/v1/responses", body: { input: [] } }), { id: "resp_1", output: [] });
  assert.deepEqual(t.calls.map(call => call.url), ["https://agent.example/v1/session", "https://agent.example/v1/responses"]);
  for (const call of t.calls) {
    assert.equal(call.init.method, "POST");
    assert.equal(call.init.credentials, "omit");
    assert.equal(call.init.redirect, "error");
    assert.equal(call.init.cache, "no-store");
    assert.equal(call.init.mode, "cors");
    assert.equal(call.headers.get("authorization"), `Bearer ${TOKEN}`);
    assert.equal(call.headers.get("x-ppomi-device"), DEVICE);
    assert.equal(call.headers.get("content-type"), "application/json");
    assert.ok(call.init.signal instanceof AbortSignal);
  }
  assert.deepEqual(JSON.parse(String(t.calls[0].init.body)), { mode: "text" });
  assert.deepEqual(s.calls, ["token", "token"], "the token is fetched per request and never cached by the bridge");
});

test("web bridge refuses what the browser cannot do before touching the network", async () => {
  const s = source({ account: ALICE, deviceID: DEVICE });
  const t = transport(() => Response.json({}));
  const bridge = createWebBridge(s, { fetch: t.fetcher });
  await rejects(bridge.call("request", { path: "/v1/memories/list", body: {} }), "native_unavailable");
  await rejects(bridge.call("request", { path: "/v1/memories/save", body: { text: "x" } }), "native_unavailable");
  await rejects(bridge.call("request", { path: "/v1/other", body: {} }), "invalid_request");
  await rejects(bridge.call("request", { path: "/v1/session", body: [] }), "invalid_request");
  await rejects(bridge.call("request", { path: "/v1/session", body: {}, extra: 1 }), "invalid_request");
  await rejects(bridge.call("executeTool", { name: "screen_read", args: {} }), "native_unavailable");
  await rejects(bridge.call("transcriptOpen", {}), "native_unavailable");
  await rejects(bridge.call("transcriptAppend", { turn: { id: DEVICE, role: "user", parts: [] } }), "native_unavailable");
  await rejects(bridge.call("sessionState", { active: true, mode: "voice" }), "native_unavailable");
  await rejects(bridge.call("sessionState", { active: "yes" }), "invalid_request");
  await rejects(bridge.call("setEndpoint", { endpoint: "https://x.example" }), "invalid_request");
  await rejects(bridge.call("bankProfileRequest", {}), "invalid_request");
  assert.deepEqual(await bridge.call("sessionState", { active: true, mode: "text" }), { active: true });
  assert.deepEqual(await bridge.call("sessionState", { active: false }), { active: false });
  assert.deepEqual(await bridge.call("declineCall", {}), { declined: true });
  assert.deepEqual(await bridge.call("heard", { text: "승인" }), {});
  assert.deepEqual(await bridge.call("updateReady", { bridgeVersion: 1 }), { ready: true });
  assert.equal((await bridge.call<{ platform: string }>("bootstrap")).platform, "web");
  assert.equal(t.calls.length, 0);
  assert.deepEqual(s.calls, []);
  assert.equal(bridge.pendingCount, 0);
});

test("web bridge maps account, server and transport failures to the shared codes", async () => {
  const signedOut = source();
  const idle = transport(() => Response.json({}));
  await rejects(createWebBridge(signedOut, { fetch: idle.fetcher }).call("request", { path: "/v1/session", body: {} }), "server_unconfigured");
  signedOut.set({ account: ALICE });
  await rejects(createWebBridge(signedOut, { fetch: idle.fetcher }).call("request", { path: "/v1/session", body: {} }), "server_unconfigured");
  assert.equal(idle.calls.length, 0);

  const s = source({ account: ALICE, deviceID: DEVICE });
  let status = 200, body: unknown = { model: "m" }, fail = false;
  const t = transport(() => {
    if (fail) throw new TypeError("network down");
    return new Response(typeof body === "string" ? body : JSON.stringify(body), { status, headers: { "content-type": "application/json" } });
  });
  const bridge = createWebBridge(s, { fetch: t.fetcher });
  status = 401; body = { error: { code: "unauthenticated", message: "secret upstream detail" } };
  await rejects(bridge.call("request", { path: "/v1/session", body: {} }), "server_auth");
  status = 403;
  await rejects(bridge.call("request", { path: "/v1/session", body: {} }), "server_auth");
  status = 503; body = { error: { code: "not_configured" } };
  await rejects(bridge.call("request", { path: "/v1/session", body: {} }), "server_rejected");
  status = 429;
  await rejects(bridge.call("request", { path: "/v1/responses", body: { input: [] } }), "server_rejected");
  status = 200; body = "[1,2,3]";
  await rejects(bridge.call("request", { path: "/v1/session", body: {} }), "response_invalid");
  body = "not json";
  await rejects(bridge.call("request", { path: "/v1/session", body: {} }), "response_invalid");
  body = JSON.stringify({ padding: "x".repeat(600 * 1024) });
  await rejects(bridge.call("request", { path: "/v1/session", body: {} }), "response_invalid");
  fail = true;
  await rejects(bridge.call("request", { path: "/v1/session", body: {} }), "server_unavailable");
  fail = false; body = { model: "m" };
  s.failToken();
  await rejects(bridge.call("request", { path: "/v1/session", body: {} }), "server_auth");
  assert.equal(bridge.pendingCount, 0);
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
function recorder() {
  const calls: string[] = [];
  const events: ChatHostEvents = {
    stop: () => calls.push("stop"), refresh: () => calls.push("refresh"),
    answerCall: () => calls.push("answer"), incomingCall: () => calls.push("incoming"),
    toolProgress: () => calls.push("progress"), notice: () => calls.push("notice"),
  };
  return { events, calls };
}
function host(initial: Partial<WebHostState> = {}) {
  const s = source(initial);
  const window = eventsTarget();
  const styles = new Map<string, string | null>();
  const document = {
    ...eventsTarget(), visibilityState: "visible",
    documentElement: { style: { setProperty: (name: string, value: string | null) => { styles.set(name, value); } }, dataset: {} as Record<string, string | undefined> },
  };
  const t = transport(() => Response.json({ model: "m" }));
  const chatHost = createWebChatHost({ source: s, window, document, fetch: t.fetcher });
  return { s, window, document, styles, chatHost, calls: t.calls };
}

test("web chat host refreshes on account or device changes and ends the conversation when the account changes", () => {
  const h = host(), r = recorder();
  const unsubscribe = h.chatHost.subscribe(r.events);
  h.s.set({ notice: "로그인 상태를 확인하고 있습니다." });
  assert.deepEqual(r.calls, ["refresh"], "a notice alone refreshes the bootstrap");
  h.s.set({ account: ALICE });
  assert.deepEqual(r.calls, ["refresh", "stop", "refresh"], "sign-in is an account change: any stale conversation ends first");
  h.s.set({ deviceID: DEVICE });
  assert.deepEqual(r.calls, ["refresh", "stop", "refresh", "refresh"], "device confirmation only refreshes");
  h.s.set({ account: null, deviceID: null });
  assert.deepEqual(r.calls.slice(4), ["stop", "refresh"], "sign-out ends the conversation");
  h.window.dispatch("pagehide");
  h.window.dispatch("focus");
  h.document.dispatch("visibilitychange");
  assert.deepEqual(r.calls.slice(6), ["stop", "refresh", "refresh"]);
  h.document.visibilityState = "hidden";
  h.s.set({ account: ALICE });
  h.window.dispatch("focus");
  assert.deepEqual(r.calls.slice(9), ["stop"], "a hidden document never refreshes");
  unsubscribe();
  h.s.set({ account: null });
  h.window.dispatch("pagehide");
  assert.deepEqual(r.calls.slice(10), []);
  assert.equal(h.s.listeners.size, 0);
  assert.equal(h.window.count("pagehide"), 0);
  assert.equal(h.document.count("visibilitychange"), 0);
});

test("web chat host readiness needs no native acknowledgement and keeps the appearance rules", async () => {
  const h = host({ account: ALICE, deviceID: DEVICE });
  const boot = h.chatHost.readiness.prepare(await h.chatHost.bridge.call("bootstrap"));
  await h.chatHost.readiness.commit();
  assert.equal((await h.chatHost.readiness.wait()).configured, true);
  h.chatHost.applyBootstrap(boot);
  assert.equal(h.styles.get("--ui-scale"), "1");
  assert.equal(h.document.documentElement.dataset.theme, undefined, "the web follows the system scheme unless a host names one");
  h.chatHost.readiness.prepare({ ...boot, configured: false });
  assert.equal((await h.chatHost.readiness.wait()).configured, false, "sign-out refreshes the same release identity");
  assert.equal(h.calls.length, 0, "readiness never calls the server");
});
