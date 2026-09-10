import assert from 'node:assert/strict';
import test from 'node:test';
import { randomBytes } from 'node:crypto';
import { readFile } from 'node:fs/promises';
import { createHandler } from './handler.js';

const WORKSPACE = 'aaaaaaaa-1111-4111-8111-111111111111';
const DEVICE = 'dddddddd-1111-4111-8111-111111111111';
const ID = 'bbbbbbbb-1111-4111-8111-111111111111';
const NEXT = 'cccccccc-1111-4111-8111-111111111111';
const environment = () => ({ SUPABASE_URL: 'https://abcdefghijklmnopqrst.supabase.co', SUPABASE_ANON_KEY: 'sb_publishable_test_public_key_only_123456', OPENAI_API_KEY: 'server-only-test-key', AI_GATEWAY_API_KEY: 'gateway-only-test-key', PPOMI_AGENT_MEMORY_KEY: randomBytes(32).toString('base64') });
type Row = { id: string; workspace_id: string; replaces_id: string | null; created_at: string; deleted_at: string | null; envelope: Record<string, unknown>; request_digest: string };
function fixture() {
  const env = environment(), rows = new Map<string, Row>(), calls: { url: string; body: Record<string, unknown>; auth: string; safety: string | null; device: string | null }[] = [];
  let active = true;
  const transport = (async (url: string | URL | Request, init?: RequestInit) => {
    const address = String(url), body = JSON.parse(String(init?.body)) as Record<string, unknown>;
    const auth = new Headers(init?.headers).get('authorization') ?? '';
    calls.push({ url: address, body, auth, safety: new Headers(init?.headers).get('OpenAI-Safety-Identifier'), device: new Headers(init?.headers).get('x-ppomi-device') });
    assert.equal(init?.redirect, 'error');
    assert.equal(init?.cache, 'no-store');
    const json = (data: unknown, status = 200) => Response.json(data, { status });
    if (address.endsWith('ppomi_context')) return active ? json({ workspace: { id: WORKSPACE }, device: { id: DEVICE } }) : json({ sensitive_upstream_details: 'must not leak' }, 403);
    if (address.endsWith('/client_secrets')) return json({ value: 'ek_ephemeral_test_only', expires_at: 100, session: { id: 'not-returned' } });
    if (address.endsWith('ppomi_agent_memory_list')) return json([...rows.values()].filter(row => row.deleted_at === null && ![...rows.values()].some(child => child.replaces_id === row.id)));
    if (address.endsWith('ppomi_agent_memory_save')) {
      const old = rows.get(String(body.p_id));
      if (old) return old.deleted_at ? json({}, 410) : old.request_digest === body.p_request_digest && old.replaces_id === body.p_replaces_id ? json(old) : json({}, 409);
      const row: Row = { id: String(body.p_id), workspace_id: WORKSPACE, replaces_id: body.p_replaces_id as string | null, created_at: '2026-09-09T13:00:00Z', deleted_at: null, envelope: body.p_envelope as Record<string, unknown>, request_digest: String(body.p_request_digest) };
      rows.set(row.id, row); return json(row);
    }
    if (address.endsWith('ppomi_agent_memory_delete')) {
      const old = rows.get(String(body.p_id));
      if (!old) return json({}, 404);
      let ancestor: Row | undefined = old;
      while (ancestor) { ancestor.deleted_at = '2026-09-09T14:00:00Z'; ancestor.envelope = {}; ancestor = ancestor.replaces_id ? rows.get(ancestor.replaces_id) : undefined; }
      return json({ deleted: true });
    }
    throw new Error('Unexpected endpoint');
  }) as typeof fetch;
  const handle = createHandler({ env, fetch: transport });
  return { env, calls, rows, revoke: () => { active = false; }, handle };
}
const memory = (extra = {}) => ({ id: ID, kind: 'preference', text: '답변은 한국어로 간결하게 받는 것을 선호한다.', source: 'user_reported', confidence: 0.9, ...extra });
const request = (path: string, body: unknown = {}, headers = {}) => new Request(`https://agent.example${path}`, {
  method: 'POST', headers: { 'Content-Type': 'application/json', Authorization: 'Bearer test.device.signature', ...headers }, body: JSON.stringify(body),
});

test('missing auth and browser origin fail before any upstream request', async () => {
  const f = fixture();
  assert.equal((await f.handle(request('/v1/session', {}, { Authorization: '' }))).status, 401);
  assert.equal((await f.handle(request('/v1/session', {}, { Origin: 'https://other.example' }))).status, 403);
  assert.equal(f.calls.length, 0);
});

test('a Google-account device names itself in a header that reaches the shared server as-is', async () => {
  const f = fixture();
  assert.equal((await f.handle(request('/v1/memories/list', {}, { 'X-Ppomi-Device': DEVICE.toUpperCase() }))).status, 200);
  assert.equal(f.calls.find(call => call.url.endsWith('ppomi_context'))?.device, DEVICE);
  const before = f.calls.length;
  assert.equal((await f.handle(request('/v1/memories/list', {}, { 'X-Ppomi-Device': 'not-a-device-id' }))).status, 401);
  assert.equal(f.calls.length, before);   // a malformed header never reaches the server
  assert.equal((await f.handle(request('/v1/memories/list'))).status, 200);
  assert.equal(f.calls.at(-1)?.device ?? null, null);   // legacy devices send no header and none is invented
});

test('every request rechecks active device; no reused authentication context', async () => {
  const f = fixture();
  assert.equal((await f.handle(request('/v1/memories/list'))).status, 200);
  f.revoke();
  const denied = await f.handle(request('/v1/session'));
  assert.equal(denied.status, 403);
  assert.equal(f.calls.filter(call => call.url.endsWith('ppomi_context')).length, 2);
  assert.equal(f.calls.some(call => call.url.endsWith('client_secrets')), false);
  assert.equal((await denied.text()).includes('sensitive_upstream_details'), false);
});

test('session mints only ephemeral credential with tracing disabled and call transcription on', async () => {
  const f = fixture(), response = await f.handle(request('/v1/session'));
  assert.equal(response.status, 200);
  assert.deepEqual(await response.json(), { clientSecret: 'ek_ephemeral_test_only', model: 'gpt-realtime-2.1' });
  assert.match(response.headers.get('cache-control') ?? '', /no-store/);
  const call = f.calls.at(-1)!;
  assert.match(call.safety ?? '', /^[a-f0-9]{64}$/);
  assert.equal(call.safety?.includes(DEVICE), false);
  assert.deepEqual(call.body, { expires_after: { anchor: 'created_at', seconds: 60 }, session: { type: 'realtime', model: 'gpt-realtime-2.1', tracing: null, audio: { input: { transcription: { model: 'gpt-4o-mini-transcribe' } }, output: { voice: 'marin' } } } });
  assert.equal(f.rows.size, 0);
});

test('text sessions name the gateway model and mint no realtime secret', async () => {
  const f = fixture(), response = await f.handle(request('/v1/session', { mode: 'text' }));
  assert.equal(response.status, 200);
  assert.deepEqual(await response.json(), { model: 'openai/gpt-6-astra' });
  assert.match(response.headers.get('cache-control') ?? '', /no-store/);
  assert.equal(f.calls.filter(item => item.url.endsWith('/client_secrets')).length, 0);
  assert.equal(f.rows.size, 0);
  f.revoke();
  assert.equal((await f.handle(request('/v1/session', { mode: 'text' }))).status, 403);
  const unconfigured = createHandler({ env: { ...f.env, AI_GATEWAY_API_KEY: undefined }, fetch: (async () => Response.json({ workspace: { id: WORKSPACE }, device: { id: DEVICE } })) as typeof fetch });
  assert.equal((await unconfigured(request('/v1/session', { mode: 'text' }))).status, 503);
});

test('explicit voice mode preserves legacy mint configuration; invalid modes cannot mint', async () => {
  const f = fixture();
  assert.equal((await f.handle(request('/v1/session'))).status, 200);
  const legacy = f.calls.at(-1)!.body;
  assert.equal((await f.handle(request('/v1/session', { mode: 'voice' }))).status, 200);
  assert.deepEqual(f.calls.at(-1)!.body, legacy);
  for (const body of [{ mode: null }, { mode: 'audio' }, { mode: ['text'] }, { mode: 'text', transcript: 'private' }, { mode: 'text', history: [] }])
    assert.equal((await f.handle(request('/v1/session', body))).status, 400);
  assert.equal(f.calls.filter(item => item.url.endsWith('/client_secrets')).length, 2);
  assert.equal(f.rows.size, 0);
});

test('session rejects transcript/history input and exposes no provider errors', async () => {
  const f = fixture();
  assert.equal((await f.handle(request('/v1/session', { transcript: 'private raw conversation' }))).status, 400);
  assert.equal(f.calls.some(call => call.url.endsWith('client_secrets')), false);
  const broken = createHandler({ env: f.env, fetch: (async (url) => String(url).endsWith('ppomi_context')
    ? Response.json({ workspace: { id: WORKSPACE }, device: { id: DEVICE } })
    : Response.json({ api_key: 'sensitive-upstream-value' }, { status: 500 })) as typeof fetch });
  const failure = await broken(request('/v1/session'));
  assert.equal(failure.status, 502);
  assert.equal((await failure.text()).includes('sensitive-upstream-value'), false);
});

test('memory is authenticated ciphertext in DB and carries epistemic source without promotion', async () => {
  const f = fixture(), input = memory({ source: 'ai_inferred', confidence: 0.3 });
  const response = await f.handle(request('/v1/memories/save', input));
  assert.equal(response.status, 200);
  const { record } = await response.json();
  assert.equal(record.source, 'ai_inferred'); assert.equal(record.confidence, 0.3); assert.equal(record.selection, 'automatic');
  assert.equal(record.text, input.text);
  assert.equal(JSON.stringify([...f.rows.values()]).includes(input.text), false);
  const listed = await (await f.handle(request('/v1/memories/list'))).json();
  assert.deepEqual(listed.records, [record]);
  for (const call of f.calls) assert.equal(call.auth, 'Bearer test.device.signature');
});

test('same ID/content retry returns original record despite fresh nonces; changed input conflicts', async () => {
  const f = fixture();
  const first = await (await f.handle(request('/v1/memories/save', memory()))).json();
  const second = await (await f.handle(request('/v1/memories/save', memory()))).json();
  assert.deepEqual(second, first); assert.equal(f.rows.size, 1);
  const saves = f.calls.filter(call => call.url.endsWith('ppomi_agent_memory_save'));
  assert.equal(saves[0]!.body.p_request_digest, saves[1]!.body.p_request_digest);
  assert.notDeepEqual(saves[0]!.body.p_envelope, saves[1]!.body.p_envelope);
  assert.equal((await f.handle(request('/v1/memories/save', memory({ text: '다른 내용' })))).status, 409);
});

test('replacement retains old ciphertext and deletion tombstones never resurrect prior content', async () => {
  const f = fixture();
  await f.handle(request('/v1/memories/save', memory()));
  await f.handle(request('/v1/memories/save', memory({ id: NEXT, replacesId: ID, text: '이제는 자세한 답변을 선호한다.' })));
  assert.equal(f.rows.size, 2);
  assert.equal((await (await f.handle(request('/v1/memories/list'))).json()).records[0].id, NEXT);
  assert.deepEqual(await (await f.handle(request('/v1/memories/delete', { id: NEXT }))).json(), { deleted: true });
  assert.deepEqual([...f.rows.values()].map(row => row.envelope), [{}, {}]);
  assert.equal((await (await f.handle(request('/v1/memories/list'))).json()).records.length, 0);
  assert.equal(f.rows.size, 2);
  assert.equal((await f.handle(request('/v1/memories/save', memory({ id: NEXT, replacesId: ID, text: '이제는 자세한 답변을 선호한다.' })))).status, 409);
  assert.equal((await f.handle(request('/v1/memories/delete', { id: NEXT }))).status, 200);
});

test('ciphertext tamper and workspace binding fail closed with safe errors', async () => {
  const f = fixture();
  await f.handle(request('/v1/memories/save', memory()));
  const row = f.rows.get(ID)!;
  row.envelope.tag = 'AAAAAAAAAAAAAAAAAAAAAA';
  assert.equal((await f.handle(request('/v1/memories/list'))).status, 502);
  row.workspace_id = 'eeeeeeee-1111-4111-8111-111111111111';
  const failure = await f.handle(request('/v1/memories/list'));
  assert.equal(failure.status, 502); assert.equal((await failure.text()).includes(memory().text), false);
});

test('known secrets, raw transcripts, unknown fields, invalid sources/confidence and large bodies rejected', async () => {
  const f = fixture();
  const bad = [memory({ text: 'password: example-secret' }), memory({ text: 'sk-proj-abcdefghijklmnopqrstuvwxy' }),
    memory({ text: '사용자: 안녕\n어시스턴트: 반갑습니다' }), memory({ transcript: 'raw' }), memory({ source: 'confirmed' }),
    memory({ source: ['user_reported'] }), memory({ confidence: -1 }), memory({ confidence: 1.1 }), memory({ text: 'x'.repeat(2001) }), memory({ replacesId: ID })];
  for (const body of bad) assert.equal((await f.handle(request('/v1/memories/save', body))).status, 400);
  assert.equal((await f.handle(request('/v1/memories/save', memory({ text: 'x'.repeat(17_000) })))).status, 413);
  assert.equal(f.rows.size, 0);
});

test('misconfigured admin key and missing memory key fail closed without exposing environment', async () => {
  const f = fixture();
  f.env.SUPABASE_ANON_KEY = 'sb_secret_do_not_expose_this_value';
  const response = await f.handle(request('/v1/session'));
  assert.equal(response.status, 503); assert.equal((await response.text()).includes('sb_secret'), false);
  const g = fixture(); g.env.PPOMI_AGENT_MEMORY_KEY = '';
  assert.equal((await g.handle(request('/v1/memories/save', memory()))).status, 503);
  assert.equal(g.rows.size, 0);
});

test('server implementation has no transcript persistence, raw logging, or filesystem writes', async () => {
  const source = await readFile(new URL('./handler.ts', import.meta.url), 'utf8');
  assert.equal(/console\.|writeFile|appendFile|localStorage|sessionStorage|createWriteStream/.test(source), false);
  assert.equal(/from ['"]node:fs/.test(source), false);
  // The text chat proxy is the one model endpoint the server may relay: no storage upstream, no streaming, no memory of the turn.
  assert.equal(/\/v1\/(?:conversations|chat\/completions)/.test(source), false);
  assert.match(source, /model: textModel, stream: false, store: false/);
});

test('the text proxy relays one turn to the AI Gateway with the server-side key, model, stream and store', async () => {
  const env = environment(), calls: { url: string; body: Record<string, unknown>; auth: string | null }[] = [];
  const transport = (async (url: string | URL | Request, init?: RequestInit) => {
    const address = String(url), body = JSON.parse(String(init?.body)) as Record<string, unknown>;
    calls.push({ url: address, body, auth: new Headers(init?.headers).get('Authorization') });
    if (address.endsWith('ppomi_context')) return Response.json({ workspace: { id: WORKSPACE }, device: { id: DEVICE } });
    if (address.endsWith('/v1/responses')) return Response.json({ id: 'resp_1', object: 'response', output: [{ type: 'message', role: 'assistant', content: [{ type: 'output_text', text: '네' }] }] });
    throw new Error('Unexpected endpoint ' + address);
  }) as typeof fetch;
  const handle = createHandler({ env, fetch: transport });
  const proxied = await handle(request('/v1/responses', { model: 'gpt-4o-mini', stream: false, store: true, instructions: 'x', input: [{ role: 'user', content: '안녕' }], tools: [] }));
  assert.equal(proxied.status, 200);
  assert.equal(((await proxied.json()) as { id: string }).id, 'resp_1');
  const upstream = calls.find(call => call.url === 'https://ai-gateway.vercel.sh/v1/responses')!;
  assert.equal(upstream.body.model, 'openai/gpt-6-astra'); assert.equal(upstream.body.stream, false); assert.equal(upstream.body.store, false);
  assert.equal(upstream.body.instructions, 'x'); assert.equal(upstream.auth, 'Bearer gateway-only-test-key');
  assert.ok(!calls.some(call => call.url.includes('api.openai.com')));
  assert.equal((await handle(request('/v1/responses', { input: [], stream: true }))).status, 400);
  assert.equal((await handle(request('/v1/responses', { instructions: 'no input' }))).status, 400);
  assert.equal((await handle(request('/v1/session', { mode: 'text', responses: true }))).status, 400);
  const oidc = createHandler({ env: { ...env, AI_GATEWAY_API_KEY: undefined, VERCEL_OIDC_TOKEN: 'oidc-test-token', AI_TEXT_MODEL: 'openai/gpt-5.6-sol' }, fetch: transport });
  assert.equal((await oidc(request('/v1/responses', { input: [] }))).status, 200);
  assert.equal(calls.at(-1)?.auth, 'Bearer oidc-test-token'); assert.equal(calls.at(-1)?.body.model, 'openai/gpt-5.6-sol');
  const header = createHandler({ env: { ...env, AI_GATEWAY_API_KEY: undefined }, fetch: transport });
  assert.equal((await header(request('/v1/responses', { input: [] }, { 'x-vercel-oidc-token': 'header-oidc-token' }))).status, 200);
  assert.equal(calls.at(-1)?.auth, 'Bearer header-oidc-token');
  assert.equal((await header(request('/v1/responses', { input: [] }))).status, 503);
});
