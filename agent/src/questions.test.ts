import { test } from "node:test";
import assert from "node:assert/strict";
import React from "react";
import { renderToStaticMarkup } from "react-dom/server";
import { RunContext } from "@openai/agents";
import { RealtimeAgent, type RealtimeSession, type RealtimeItem } from "@openai/agents/realtime";
import { NativeBridge, type Bootstrap } from "./bridge";
import { QuestionRequests, type InputCard, type UserInputRequest } from "./questions";
import { QuestionCard } from "./question-cards";
import { createAgentTools, createTextSession, TextController, voiceInstructions } from "./voice";

const question: UserInputRequest = { questions: [{ id: "route", prompt: "어디에서 진행할까요?",
  options: [{ label: "현재 기기", description: "현재 화면을 사용합니다." }], allow_text: true }] };
const bank = { profile_id: "self", bank_id: "kb" as const };
const boot: Bootstrap = { platform: "macos", configured: true, deviceLabel: "Fixture", endpoint: "https://example.invalid",
  tools: [], bankProfileSupported: true };
type Call = { id: string; method: string; args: Record<string, any> };
function fixture(handler: (message: Call) => unknown = () => ({}), timeoutMs?: number) {
  const calls: Call[] = [];
  let cards: InputCard[] = [];
  const bridge = new NativeBridge(text => {
    const call = JSON.parse(text) as Call;
    calls.push(call);
    const result = handler(call);
    if (result !== undefined) queueMicrotask(() => bridge.receive({ id: call.id, result }));
  });
  const requests = new QuestionRequests(bridge, value => { cards = value; }, () => {}, timeoutMs);
  return { bridge, requests, calls, cards: () => cards };
}
const metadata = (registered = { customer_name: false, account_number: false }) =>
  ({ request_id: "synthetic-request", ...bank, label_hint: "기본 프로필 · KB", registered });
const tick = () => new Promise<void>(resolve => setTimeout(resolve, 0));

test("question tool waits for card submission and returns selected or free text answers", async t => {
  const f = fixture(); t.after(() => f.requests.close());
  const tools = createAgentTools(boot, f.bridge, () => {}, () => {}, undefined, undefined, f.requests);
  const input = tools.find(tool => tool.name === "request_user_input")!;
  let finished = false;
  const pending = input.invoke(new RunContext({}), JSON.stringify(question)).then(value => { finished = true; return value; });
  await tick();
  assert.equal(finished, false);
  assert.equal(f.cards().length, 1);
  assert.equal(f.requests.submitAnswers(f.cards()[0].id, [{ id: "wrong", answer: "현재 기기" }]), false);
  assert.equal(f.requests.submitAnswers(f.cards()[0].id, [{ id: "route", answer: "  다른 작업공간  " }]), true);
  assert.deepEqual(await pending, { status: "submitted", answers: [{ id: "route", answer: "다른 작업공간" }] });
  assert.deepEqual(f.cards(), []);
  assert.deepEqual(f.calls, []);
});

test("questions reject duplicate ids, impossible answers, too many options and unoffered fixed answers", async t => {
  const f = fixture(); t.after(() => f.requests.close());
  assert.throws(() => f.requests.requestUserInput({ questions: [question.questions[0], question.questions[0]] }));
  assert.throws(() => f.requests.requestUserInput({ questions: [{ ...question.questions[0], options: [], allow_text: false }] }));
  assert.throws(() => f.requests.requestUserInput({ questions: [{ ...question.questions[0], options: Array(4).fill(question.questions[0].options[0]) }] }));
  const pending = f.requests.requestUserInput({ questions: [{ ...question.questions[0], allow_text: false }] });
  assert.equal(f.requests.submitAnswers(f.cards()[0].id, [{ id: "route", answer: "다른 기기" }]), false);
  f.requests.cancel(f.cards()[0].id);
  assert.deepEqual(await pending, { status: "cancelled", reason: "user_cancelled" });
});

test("timeout and session close settle pending cards once and discard late submissions", async () => {
  const f = fixture(undefined, 5);
  const timeout = f.requests.requestUserInput(question);
  const oldId = f.cards()[0].id;
  assert.deepEqual(await timeout, { status: "cancelled", reason: "timeout" });
  assert.equal(f.requests.submitAnswers(oldId, [{ id: "route", answer: "현재 기기" }]), false);
  const first = f.requests.requestUserInput(question);
  const second = f.requests.requestUserInput(question);
  f.requests.close();
  assert.deepEqual(await Promise.all([first, second]), Array(2).fill({ status: "cancelled", reason: "session_ended" }));
  assert.deepEqual(f.cards(), []);
  assert.throws(() => f.requests.requestUserInput(question), { code: "session_ended" });
});

test("bank values cross only bankProfileSubmit and never card state or model tool results", async t => {
  const secret = "12345678901234";
  const f = fixture(call => call.method === "bankProfileRequest" ? { ...metadata(), account_number: secret, values: { account_number: secret } }
    : call.method === "bankProfileSubmit" ? { saved: true, ...bank, registered: { customer_name: true, account_number: true }, values: call.args.values, secret } : { cancelled: true });
  t.after(() => f.requests.close());
  const tools = createAgentTools(boot, f.bridge, () => {}, () => {}, undefined, undefined, f.requests);
  const pending = tools.find(tool => tool.name === "request_bank_profile")!.invoke(new RunContext({}), JSON.stringify(bank));
  await tick();
  assert.ok(!JSON.stringify(f.cards()).includes(secret));
  assert.ok(!JSON.stringify(f.cards()).includes("values"));
  const card = f.cards()[0];
  assert.equal(await f.requests.submitBank(card.id, { customer_name: "합성고객", account_number: secret }), true);
  const result = await pending;
  assert.deepEqual(result, { status: "saved", saved: true, ...bank, registered: { customer_name: true, account_number: true } });
  assert.ok(!JSON.stringify(result).includes(secret));
  assert.deepEqual(f.calls.map(call => call.method), ["bankProfileRequest", "bankProfileSubmit"]);
  assert.deepEqual(f.cards(), []);
});

test("fully registered bank profiles return status without a card and release the native request", async t => {
  const f = fixture(call => call.method === "bankProfileRequest" ? metadata({ customer_name: true, account_number: true }) : { cancelled: true });
  t.after(() => f.requests.close());
  const pending = f.requests.requestBankProfile(bank);
  await tick();
  assert.deepEqual(f.cards(), []);
  assert.deepEqual(await pending, { status: "already_registered", ...bank, registered: { customer_name: true, account_number: true } });
  assert.deepEqual(f.calls.map(call => call.method), ["bankProfileRequest", "bankProfileCancel"]);
});

test("new bank fields have autocomplete disabled and no password, identity or OTP input", async t => {
  const f = fixture(call => call.method === "bankProfileRequest" ? metadata({ customer_name: true, account_number: false }) : { cancelled: true });
  t.after(() => f.requests.close());
  const pending = f.requests.requestBankProfile(bank); await tick();
  const html = renderToStaticMarkup(React.createElement(QuestionCard, { card: f.cards()[0], requests: f.requests, onError: () => {} }));
  assert.ok(html.includes('name="account_number"') && !html.includes('name="customer_name"'));
  assert.ok(!html.includes("등록된 항목 변경"));
  assert.match(html, /autoComplete="off"/);
  assert.ok(!/type="password"|name="(?:password|otp|resident_number)"/.test(html));
  assert.equal(await f.requests.submitBank(f.cards()[0].id, { customer_name: "덮어쓰기", account_number: "111222333" }), false);
  assert.equal(await f.requests.submitBank(f.cards()[0].id, {}), false);
  assert.equal(f.calls.filter(call => call.method === "bankProfileSubmit").length, 0);
  f.requests.cancel(f.cards()[0].id); await pending;
});

test("late bank request and save replies cannot revive a closed session or leak values", async () => {
  const f = fixture(call => call.method === "bankProfileCancel" ? { cancelled: true } : undefined);
  const pending = f.requests.requestBankProfile(bank);
  const rejected = assert.rejects(pending, { code: "session_ended" });
  f.requests.close();
  f.bridge.receive({ id: f.calls[0].id, result: metadata() });
  await rejected;
  assert.deepEqual(f.cards(), []);
  assert.equal(f.calls.at(-1)?.method, "bankProfileCancel");

  const g = fixture(call => call.method === "bankProfileRequest" ? metadata() : call.method === "bankProfileCancel" ? { cancelled: true } : undefined);
  const waiting = g.requests.requestBankProfile(bank); await tick();
  const saving = g.requests.submitBank(g.cards()[0].id, { customer_name: "합성", account_number: "111222333" });
  const call = g.calls.find(c => c.method === "bankProfileSubmit")!;
  g.requests.close();
  g.bridge.receive({ id: call.id, result: { saved: true, ...bank, registered: { customer_name: true, account_number: true } } });
  assert.equal(await saving, false);
  assert.deepEqual(await waiting, { status: "cancelled", reason: "session_ended" });
  assert.deepEqual(g.cards(), []);
});

test("uncertain bank save closes the card without retrying and reports no false user cancellation", async () => {
  const f = fixture(call => call.method === "bankProfileRequest" ? metadata() : call.method === "bankProfileCancel" ? { cancelled: true } : undefined);
  const pending = f.requests.requestBankProfile(bank); await tick();
  const saving = f.requests.submitBank(f.cards()[0].id, { customer_name: "합성", account_number: "111222333" });
  const failed = assert.rejects(saving, { code: "tool_failed" });
  const call = f.calls.find(c => c.method === "bankProfileSubmit")!;
  f.bridge.receive({ id: call.id, error: { code: "tool_failed", message: "private-native-message" } });
  await failed;
  assert.deepEqual(await pending, { status: "failed", reason: "save_unconfirmed" });
  assert.equal(f.calls.filter(c => c.method === "bankProfileSubmit").length, 1);
  f.requests.close();
});

test("question cards are shared; bank cards require native bank profile support", async t => {
  const f = fixture(); t.after(() => f.requests.close());
  const make = (bootstrap: Bootstrap) => createAgentTools(bootstrap, f.bridge, () => {}, () => {}, undefined, undefined, f.requests);
  const android = make({ ...boot, platform: "android", bankProfileSupported: undefined });
  assert.ok(android.some(tool => tool.name === "request_user_input"));
  assert.ok(!android.some(tool => tool.name === "request_bank_profile"));
  assert.ok(!make({ ...boot, bankProfileSupported: false }).some(tool => tool.name === "request_bank_profile"));
  assert.match(voiceInstructions({ ...boot, platform: "android", bankProfileSupported: undefined }), /request_user_input/);
  assert.doesNotMatch(voiceInstructions({ ...boot, platform: "android", bankProfileSupported: undefined }), /request_bank_profile/);
  assert.match(voiceInstructions(boot), /request_bank_profile/);
  const session = createTextSession(new RealtimeAgent({ name: "fixture", tools: make(boot) }), "synthetic-model");
  try {
    const config = await session.getInitialSessionConfig();
    const schema = config.tools?.find(tool => tool.type === "function" && tool.name === "request_bank_profile");
    assert.ok(schema && schema.type === "function");
    assert.deepEqual(Object.keys((schema.parameters as any).properties).sort(), ["bank_id", "profile_id"]);
  } finally { session.close(); }
});

test("TextController stop clears a waiting card, rejects the old tool result and starts with fresh questions", async () => {
  let cards: InputCard[] = [], agent: RealtimeAgent | undefined, session: RealtimeSession | undefined;
  const bridge = new NativeBridge(text => {
    const call = JSON.parse(text);
    queueMicrotask(() => bridge.receive({ id: call.id, result: call.method === "bootstrap" ? boot
      : call.method === "request" ? { clientSecret: "ek_synthetic", model: "synthetic-model" } : { active: call.args.active } }));
  });
  const controller = new TextController(bridge, () => {}, () => {}, () => {}, () => {}, (next, model) => {
    agent = next; session = createTextSession(next, model); session.connect = async () => {}; return session;
  }, value => { cards = value; });
  await controller.start(boot);
  const context = new RunContext({ history: [] as RealtimeItem[] });
  const tools = await agent!.getAllTools(context);
  const input = tools.find(tool => tool.name === "request_user_input")!;
  assert.equal(input.type, "function");
  assert.ok(input.type === "function");
  const pending = input.invoke(context, JSON.stringify(question));
  await tick(); assert.equal(cards.length, 1);
  const old = controller.questionRequests;
  await controller.stop();
  assert.equal(JSON.parse(String(await pending)).error.code, "session_ended");
  assert.deepEqual(cards, []); assert.deepEqual(session!.history, []);
  await controller.start(boot);
  assert.notEqual(controller.questionRequests, old);
  assert.deepEqual(cards, []);
  await controller.stop();
});
