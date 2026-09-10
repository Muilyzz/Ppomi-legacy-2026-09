import { test } from "node:test";
import assert from "node:assert/strict";
import { RunContext } from "@openai/agents";
import { RealtimeAgent, RealtimeSession } from "@openai/agents/realtime";
import { NativeBridge, NativeBridgeError, type Bootstrap } from "./bridge";
import { PlaybookLibrary, type BundledPlaybooks, type PublicPlaybook } from "./playbooks";
import { createAgentTools, type ToolProgress } from "./voice";
import { createFixturePlaybookExecutor, fixtureName } from "../scripts/playbook-smoke-fixture";

const context = { platform: "android" as const, availableNativeTools: ["app_list", "app_open", "screen_read"] };
const fixture: PublicPlaybook = {
  id: "fixture", name: "합성 앱", aliases: ["Fixture App", "가"], version: "1.0.0",
  launch: { search: "합성 앱" }, humanSteps: ["당사자가 인증합니다."],
  capabilities: [{ id: "read-accounts", title: "계좌 목록 읽기", description: "인증 후 현재 목록을 확인합니다.", inputs: [],
    steps: [{ id: "open", title: "앱 열기", kind: "open" }, { id: "auth", title: "본인 인증", kind: "human" }] }],
  guide: "# Public fixture guide\nphone_open is a procedure reference, not an available tool.",
};
const data: BundledPlaybooks = { schemaVersion: 1, source: "Catalog", sourceSha256: "synthetic-sha", commonGuide: "# Common\nconfirm_payment is an external procedure reference.", playbooks: [fixture] };
const bootstrap: Bootstrap = { platform: "android", configured: true, deviceLabel: "fixture", endpoint: "https://example.invalid", tools: [...context.availableNativeTools, "synthetic-untrusted-tool"] };
const makeTools = (check = () => {}, onProgress = (_: ToolProgress) => {}) => createAgentTools(bootstrap,
  new NativeBridge(() => assert.fail("playbook tools must never use a native or network request")), check,
  () => assert.fail("reading must not end the session"), onProgress);

test("summaries search public app names and capabilities, while reads require one exact normalized identifier", () => {
  const library = new PlaybookLibrary(data);
  assert.equal(library.list("", context).playbooks.length, 1);
  assert.equal(library.list("합성 계좌", context).playbooks[0].id, "fixture");
  assert.equal(library.list("not-found", context).playbooks.length, 0);
  assert.ok(!("guide" in library.list("", context).playbooks[0]));
  const summary = library.list("", context).playbooks[0];
  assert.deepEqual(summary.launch, fixture.launch);
  summary.launch.search = "caller mutation";
  assert.deepEqual(library.list("", context).playbooks[0].launch, fixture.launch);
  assert.deepEqual(library.read(" FIXTURE APP ", context).playbook, fixture);
  assert.equal(library.read("가", context).playbook.id, "fixture", "NFC aliases resolve consistently with the source validator");
  assert.throws(() => library.read("Fixture Ap", context), error => error instanceof NativeBridgeError && error.code === "playbook_not_found");
  for (const query of ["../fixture/guide.md", "https://example.invalid", "/private/file"]) {
    assert.throws(() => library.read(query, context), error => error instanceof NativeBridgeError && error.code === "playbook_not_found");
  }
});

test("ambiguous aliases are rejected and callers cannot mutate the bundled source through returned data", () => {
  const ambiguous = new PlaybookLibrary({ ...data, playbooks: [fixture, { ...fixture, id: "second", name: "두 번째 앱" }] });
  assert.throws(() => ambiguous.read("Fixture App", context), error => error instanceof NativeBridgeError && error.code === "playbook_ambiguous");
  const library = new PlaybookLibrary(data);
  const first = library.read("fixture", context);
  first.playbook.guide = "changed by caller";
  first.playbook.capabilities[0].steps.length = 0;
  first.availableNativeTools.push("confirm_payment");
  assert.equal(library.read("fixture", context).playbook.guide, fixture.guide);
  assert.equal(library.read("fixture", context).playbook.capabilities[0].steps.length, 2);
  assert.deepEqual(library.read("fixture", context).availableNativeTools, context.availableNativeTools);
});

test("explicit playbook names survive extra task words without selecting partial names or hiding a second named candidate", () => {
  const production = new PlaybookLibrary();
  assert.deepEqual(production.list("어카운트인포 계좌조회 초기 조회 준비", context).playbooks.map(book => book.id), ["accountinfo"]);
  const first: PublicPlaybook = { ...fixture, aliases: [...fixture.aliases, "Named Client"] };
  const second: PublicPlaybook = { ...fixture, id: "second", name: "두 번째 앱", aliases: ["Second App"] };
  const library = new PlaybookLibrary({ ...data, playbooks: [first, second] });
  assert.deepEqual(library.list("Fixture App 계좌조회 초기 조회 준비", context).playbooks.map(book => book.id), ["fixture"]);
  assert.deepEqual(library.list("가 계좌조회 초기 조회 준비", context).playbooks.map(book => book.id), ["fixture"]);
  assert.deepEqual(library.list("Named ClientApp 계좌조회", context).playbooks, []);
  assert.deepEqual(library.list("가상 계좌조회", context).playbooks, []);
  assert.deepEqual(library.list("Fixture App Second App 계좌조회", context).playbooks.map(book => book.id), ["fixture", "second"]);
  assert.deepEqual(library.list("목록 인증", context).playbooks.map(book => book.id), ["fixture", "second"], "unnamed task searches retain the existing AND matching");
});

test("production SDK playbook tools work locally and identify procedure data without granting native capabilities", async () => {
  const progress: ToolProgress[] = [];
  const tools = makeTools(() => {}, event => progress.push(event));
  const list = tools.find(tool => tool.name === "list_playbooks")!;
  const read = tools.find(tool => tool.name === "read_playbook")!;
  const summaries = await list.invoke(new RunContext({}), JSON.stringify({ query: "AccountInfo" })) as unknown as { playbooks: { id: string }[] };
  assert.equal(summaries.playbooks[0].id, "accountinfo");
  const result = await read.invoke(new RunContext({}), JSON.stringify({ query: summaries.playbooks[0].id })) as unknown as ReturnType<PlaybookLibrary["read"]>;
  assert.equal(result.playbook.id, "accountinfo");
  assert.equal(result.procedureOnly, true);
  assert.equal(result.authorizesActions, false);
  assert.equal(result.platform, "android");
  assert.deepEqual([...result.availableNativeTools].sort(), [...context.availableNativeTools].sort());
  assert.ok(result.playbook.guide.length > 0 && result.commonGuide.length > 0);
  assert.deepEqual(progress.map(event => [event.name, event.status]), [["list_playbooks", "running"], ["list_playbooks", "success"], ["read_playbook", "running"], ["read_playbook", "success"]]);
  assert.ok(!JSON.stringify(progress).includes(result.playbook.guide));
  const session = new RealtimeSession(new RealtimeAgent({ name: "fixture", tools }), { transport: "websocket" });
  try {
    const config = await session.getInitialSessionConfig();
    for (const name of ["list_playbooks", "read_playbook"]) {
      const definition = config.tools?.find(tool => tool.type === "function" && tool.name === name);
      assert.ok(definition && definition.type === "function");
      assert.deepEqual((definition.parameters as { required: unknown }).required, ["query"]);
    }
    assert.ok(!config.tools?.some(tool => tool.type === "function" && tool.name === "confirm_payment"));
  } finally { session.close(); }
});

test("the production AccountInfo route preserves its identity without granting browser or Windows tools on either host", async () => {
  for (const platform of ["android", "macos"] as const) {
    const nativeTools = platform === "android" ? context.availableNativeTools : ["device_status", "file_list", "file_read", "file_write"];
    const boot = { ...bootstrap, platform, tools: nativeTools };
    const tools = createAgentTools(boot, new NativeBridge(() => assert.fail("procedure lookup must not execute an app, browser, or transfer")),
      () => {}, () => assert.fail("lookup must not end the session"));
    const read = tools.find(tool => tool.name === "read_playbook")!;
    const result = await read.invoke(new RunContext({}), JSON.stringify({ query: "AccountInfo" })) as unknown as ReturnType<PlaybookLibrary["read"]>;
    assert.equal(result.playbook.id, "accountinfo");
    assert.equal(result.playbook.launch.target, "browser");
    const list = tools.find(tool => tool.name === "list_playbooks")!;
    const summary = await list.invoke(new RunContext({}), JSON.stringify({ query: "AccountInfo" })) as unknown as ReturnType<PlaybookLibrary["list"]>;
    assert.deepEqual(summary.playbooks[0].launch, result.playbook.launch);
    const url = new URL(result.playbook.launch.search);
    assert.equal(url.protocol, "https:");
    assert.equal(url.username + url.password, "");
    assert.equal(result.platform, platform);
    assert.equal(result.authorizesActions, false);
    assert.deepEqual([...result.availableNativeTools].sort(), [...nativeTools].sort());
    assert.ok(!tools.some(tool => ["browser_open", "windows_open", "handoff", "transfer_session"].includes(tool.name)));
  }
});

test("the Android auth-resume smoke isolates synthetic procedures while preserving production tool schemas and stopped-session guards", async () => {
  let active = true;
  const progress: ToolProgress[] = [];
  const production = makeTools();
  const fixtureTools = createAgentTools(bootstrap,
    new NativeBridge(() => assert.fail("fixture procedure lookup must remain local")),
    () => { if (!active) throw new NativeBridgeError("session_ended"); },
    () => assert.fail("fixture lookup must not end the session"),
    event => progress.push(event), createFixturePlaybookExecutor());
  for (const name of ["list_playbooks", "read_playbook"]) {
    const original = production.find(tool => tool.name === name)!;
    const replacement = fixtureTools.find(tool => tool.name === name)!;
    assert.deepEqual(replacement.parameters, original.parameters);
    assert.equal(replacement.description, original.description);
  }
  assert.deepEqual(fixtureTools.find(tool => tool.name === "app_open")!.parameters, production.find(tool => tool.name === "app_open")!.parameters);
  const list = fixtureTools.find(tool => tool.name === "list_playbooks")!;
  const read = fixtureTools.find(tool => tool.name === "read_playbook")!;
  const summaries = await list.invoke(new RunContext({}), JSON.stringify({ query: fixtureName })) as unknown as ReturnType<PlaybookLibrary["list"]>;
  assert.deepEqual(summaries.playbooks.map(book => book.id), ["synthetic-accounts"]);
  const result = await read.invoke(new RunContext({}), JSON.stringify({ query: "synthetic-accounts" })) as unknown as ReturnType<PlaybookLibrary["read"]>;
  assert.equal(result.source, "synthetic-test-fixture");
  assert.ok(!JSON.stringify(result).includes("com.kftc"));
  assert.equal(result.authorizesActions, false);
  assert.equal(JSON.parse(String(await read.invoke(new RunContext({}), JSON.stringify({ query: "accountinfo" })))).error.code, "playbook_not_found");
  const real = await production.find(tool => tool.name === "read_playbook")!.invoke(new RunContext({}), JSON.stringify({ query: "accountinfo" })) as unknown as ReturnType<PlaybookLibrary["read"]>;
  assert.equal(real.source, "Catalog");
  assert.equal(real.playbook.launch.target, "browser");
  active = false;
  const stopped = await read.invoke(new RunContext({}), JSON.stringify({ query: "synthetic-accounts" }));
  assert.equal(JSON.parse(String(stopped)).error.code, "session_ended");
  assert.ok(!JSON.stringify(progress).includes(result.playbook.guide));
});

test("unknown playbook and stopped-session errors reach the model without query or guide contents", async () => {
  const read = makeTools().find(tool => tool.name === "read_playbook")!;
  const missing = String(await read.invoke(new RunContext({}), JSON.stringify({ query: "synthetic-private-query" })));
  assert.equal(JSON.parse(missing).error.code, "playbook_not_found");
  assert.ok(!missing.includes("synthetic-private-query"));
  let checks = 0;
  const stopped = makeTools(() => { if (++checks > 1) throw new NativeBridgeError("session_ended"); }).find(tool => tool.name === "read_playbook")!;
  const late = String(await stopped.invoke(new RunContext({}), JSON.stringify({ query: "accountinfo" })));
  assert.equal(JSON.parse(late).error.code, "session_ended");
  assert.ok(!late.includes("guide") && !late.includes("com.kftc"));
  const inactive = makeTools(() => { throw new NativeBridgeError("session_ended"); }).find(tool => tool.name === "list_playbooks")!;
  assert.equal(JSON.parse(String(await inactive.invoke(new RunContext({}), JSON.stringify({ query: "" })))).error.code, "session_ended");
});
