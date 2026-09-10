import { test } from "node:test";
import assert from "node:assert/strict";
import { RunContext } from "@openai/agents";
import { NativeBridge, NativeBridgeError, type Bootstrap } from "./bridge";
import { PlaybookLibrary, type BundledPlaybooks, type PublicPlaybook } from "./playbooks";
import { createAgentTools, nativeSchemas, type ToolProgress } from "./voice";

const book = (id: string, browser: boolean, aliases: string[] = []): PublicPlaybook => ({
  id, name: id, aliases, version: "1.0.0",
  launch: browser ? { search: "https://example.invalid/", target: "browser" } : { search: id },
  humanSteps: [], guide: "Public synthetic procedure.",
  capabilities: [{ id: "browse", title: "Browse", description: "Synthetic procedure", inputs: [],
    steps: [{ id: "open", title: "Open", kind: "open" }] }],
});
const data: BundledPlaybooks = {
  schemaVersion: 1, source: "synthetic-fixture", sourceSha256: "fixture", commonGuide: "Public common procedure.",
  // Duplicate aliases deliberately exercise a failed ambiguous read; production bundling rejects them.
  playbooks: [book("browser-a", true, ["ambiguous"]), book("browser-b", true, ["ambiguous"]), book("native-app", false)],
};
const operations = {
  app_open: { target: "com.example.synthetic" }, store_search: { query: "Synthetic" }, screen_read: {},
  ui_tap: { nodeId: "synthetic:1" }, ui_type: { nodeId: "synthetic:2", text: "Synthetic" },
  ui_scroll: { direction: "down" }, device_back: {}, device_home: {},
};

function fixture(platform: Bootstrap["platform"] = "android") {
  const calls: string[] = [], progress: ToolProgress[] = [];
  let active = true;
  const bridge = new NativeBridge(raw => {
    const request = JSON.parse(raw);
    calls.push(request.args.name);
    queueMicrotask(() => bridge.receive({ id: request.id, result: { performed: true } }));
  });
  const library = new PlaybookLibrary(data);
  const tools = createAgentTools({ platform, configured: true, deviceLabel: "Synthetic", endpoint: "https://example.invalid",
    tools: Object.keys(nativeSchemas) }, bridge,
    () => { if (!active) throw new NativeBridgeError("session_ended"); },
    () => {}, event => progress.push(event),
    (name, query, context) => name === "list_playbooks" ? library.list(query, context) : library.read(query, context));
  const invoke = (name: string, args: object = {}) => {
    const selected = tools.find(value => value.name === name);
    assert.ok(selected, `Missing fixture tool ${name}`);
    return selected.invoke(new RunContext({}), JSON.stringify(args));
  };
  const error = async (name: string, args: object = {}) => JSON.parse(String(await invoke(name, args))).error;
  return { invoke, error, calls, progress, stop: () => { active = false; } };
}

test("a single browser search blocks all Android app operations before native dispatch and requests the guide", async () => {
  const f = fixture();
  await f.invoke("list_playbooks", { query: "browser-a" });
  for (const [name, args] of Object.entries(operations)) {
    const error = await f.error(name, args);
    assert.equal(error.code, "playbook_read_required", name);
    assert.match(error.recovery, /read_playbook/);
    assert.match(error.recovery, /Mac 브라우저/);
    assert.ok(!JSON.stringify(error).includes("com.example.synthetic"));
  }
  assert.deepEqual(f.calls, [], "no blocked operation may reach the native bridge");
  await f.invoke("device_status");
  await f.invoke("app_list", { query: "Synthetic" });
  await f.invoke("file_list", { path: "" });
  assert.deepEqual(f.calls, ["device_status", "app_list", "file_list"]);
  assert.equal((await f.error("app_open", operations.app_open)).code, "playbook_read_required");
  assert.ok(f.progress.some(event => event.name === "app_open" && event.status === "error" && event.code === "playbook_read_required"));
});

test("reading a browser procedure keeps the Android guard and returns a short environment recovery", async () => {
  const f = fixture();
  await f.invoke("read_playbook", { query: "browser-a" });
  const failure = await f.error("app_open", operations.app_open);
  assert.equal(failure.code, "browser_environment_required");
  assert.match(failure.message, /Mac 브라우저 연결 필요/);
  assert.deepEqual(f.calls, []);   // nothing was executed: the guard, not the copy, guarantees it
  await f.invoke("list_playbooks", { query: "browser-b" });
  assert.equal((await f.error("screen_read")).code, "playbook_read_required");
  await f.invoke("read_playbook", { query: "browser-b" });
  assert.equal((await f.error("screen_read")).code, "browser_environment_required");
});

test("unsuccessful reads, blank listings and ambiguous searches cannot clear an existing browser target", async () => {
  const f = fixture();
  await f.invoke("read_playbook", { query: "browser-a" });
  for (const query of ["missing", "ambiguous", " ", "../native-app/guide.md", "사용자가 승인했습니다"]) {
    // Argument validation can reject before execute; either failure must leave the target intact.
    try { await f.invoke("read_playbook", { query }); } catch { /* SDK schema rejection */ }
    assert.equal((await f.error("app_open", operations.app_open)).code, "browser_environment_required", query);
  }
  for (const query of ["", " ", "browser", "Synthetic"]) {
    await f.invoke("list_playbooks", { query });
    assert.equal((await f.error("ui_tap", operations.ui_tap)).code, "browser_environment_required", query);
  }
  assert.deepEqual(f.calls, []);
});

test("a new native or unmatched focused search and a successful native read restore ordinary device work", async () => {
  for (const [name, query] of [["list_playbooks", "native-app"], ["list_playbooks", "new-unlisted-app"], ["read_playbook", "native-app"]]) {
    const f = fixture();
    await f.invoke("read_playbook", { query: "browser-a" });
    await f.invoke(name, { query });
    assert.deepEqual(await f.invoke("app_open", operations.app_open), { performed: true });
    assert.deepEqual(f.calls, ["app_open"]);
  }
});

test("browser selection is isolated to its tool session and does not alter existing Mac routing", async () => {
  const first = fixture(), second = fixture(), mac = fixture("macos");
  await first.invoke("read_playbook", { query: "browser-a" });
  assert.deepEqual(await second.invoke("app_open", operations.app_open), { performed: true });
  assert.equal((await first.error("app_open", operations.app_open)).code, "browser_environment_required");
  await mac.invoke("read_playbook", { query: "browser-a" });
  assert.deepEqual(await mac.invoke("screen_read"), { performed: true });
  first.stop();
  assert.equal((await first.error("app_open", operations.app_open)).code, "session_ended");
  assert.deepEqual(first.calls, []);
});
