import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createAuthClient } from '../web/auth-client.js';
import { AuthError } from '../web/auth-error.js';
import { AuthError as PublicAuthError } from '../web/auth.js';
import { SUPABASE_URL, PUBLISHABLE_KEY } from '../web/config.js';

const USER_ID = '11111111-1111-4111-8111-111111111111';
const ACCESS = 'test-only-access-token-0123456789';
const REFRESH = 'test-only-refresh-token-0123456789';
const START = 1_800_000_000_000;
const profile = () => ({ id: USER_ID, aud: 'authenticated', email: 'test@example.com', user_metadata: { full_name: 'Test user' } });
const grant = () => ({ access_token: ACCESS, refresh_token: REFRESH, expires_in: 3600, token_type: 'bearer' });
const response = value => new Response(JSON.stringify(value), { headers: { 'Content-Type': 'application/json' } });
const authCode = code => error => error instanceof AuthError && error instanceof PublicAuthError && error.code === code;

function fixture(handler) {
  const calls = [], timers = [], cancelled = [];
  const client = createAuthClient({
    now: () => START,
    fetch: async (url, options) => { calls.push({ url, options }); return handler(url, options); },
    setTimeout(callback, delay) { const timer = { callback, delay }; timers.push(timer); return timer; },
    clearTimeout: timer => cancelled.push(timer),
  });
  return { client, calls, timers, cancelled };
}

function streamed(chunks) {
  let offset = 0;
  const state = { cancelled: false, released: false };
  const reader = {
    async read() { return offset < chunks.length ? { value: chunks[offset++], done: false } : { done: true }; },
    async cancel() { state.cancelled = true; },
    releaseLock() { state.released = true; },
  };
  return { response: { ok: true, body: { getReader: () => reader } }, state };
}

test('auth client exchange and refresh return only validated session material with bounded expiry', async () => {
  const f = fixture(() => response({ ...grant(), expires_in: 900_000, token_type: 'BEARER', provider_token: 'private-provider-token', user: profile() }));
  const expected = { accessToken: ACCESS, refreshToken: REFRESH, expiresAt: START + 86_400_000 };
  assert.deepEqual(await f.client.exchangeCode('server-code', 'pkce-verifier'), expected);
  assert.deepEqual(await f.client.refresh(REFRESH), expected);
  assert.deepEqual(f.calls.map(call => call.url), [
    `${SUPABASE_URL}/auth/v1/token?grant_type=pkce`,
    `${SUPABASE_URL}/auth/v1/token?grant_type=refresh_token`,
  ]);
  assert.deepEqual(f.calls.map(call => JSON.parse(call.options.body)), [
    { auth_code: 'server-code', code_verifier: 'pkce-verifier' }, { refresh_token: REFRESH },
  ]);
  for (const { options } of f.calls) {
    assert.equal(options.method, 'POST');
    assert.equal(options.headers.Authorization, undefined);
    assert.equal(options.headers.apikey, PUBLISHABLE_KEY);
    assert.equal(options.headers.Accept, 'application/json');
    assert.equal(options.headers['Content-Type'], 'application/json');
    assert.equal(options.credentials, 'omit');
    assert.equal(options.redirect, 'error');
    assert.equal(options.cache, 'no-store');
    assert.equal(options.referrerPolicy, 'no-referrer');
  }
  assert.deepEqual(f.cancelled, f.timers);
});

test('auth client rejects malformed token grants without publishing server user claims', async () => {
  const invalid = [
    { access_token: 'too-short' }, { access_token: `${ACCESS}\n` }, { access_token: 'x'.repeat(16_385) },
    { refresh_token: '' }, { refresh_token: 'has space' }, { refresh_token: 123 },
    { expires_in: 0 }, { expires_in: -1 }, { expires_in: '3600' }, { expires_in: null },
    { token_type: 'basic' }, { token_type: 1 },
  ];
  for (const patch of invalid) {
    const f = fixture(() => response({ ...grant(), ...patch, user: profile() }));
    await assert.rejects(f.client.refresh(REFRESH), authCode('authentication'));
    assert.equal(f.calls.length, 1);
    assert.deepEqual(f.cancelled, f.timers);
  }
  const f = fixture(() => response({ access_token: ACCESS, refresh_token: REFRESH, expires_in: 0.0015 }));
  assert.equal((await f.client.refresh(REFRESH)).expiresAt, START + 1);
});

test('auth client user validation requires authenticated nonanonymous server identity', async () => {
  for (const patch of [{ id: 'untrusted-id' }, { id: 123 }, { aud: 'anon' }, { aud: ['authenticated'] }, { is_anonymous: true }]) {
    const f = fixture(() => response({ ...profile(), ...patch }));
    await assert.rejects(f.client.getUser(ACCESS), authCode('authentication'));
  }
  const f = fixture(() => response({ ...profile(), role: 'unexpected', access_token: ACCESS, user_metadata: { name: 'Fallback', picture: 'https://images.example/avatar.png' } }));
  const result = await f.client.getUser(ACCESS);
  assert.deepEqual(result, { id: USER_ID, email: 'test@example.com', name: 'Fallback', avatarURL: 'https://images.example/avatar.png' });
  assert.equal(Object.isFrozen(result), true);
  assert.equal(f.calls[0].url, `${SUPABASE_URL}/auth/v1/user`);
  assert.equal(f.calls[0].options.method, 'GET');
  assert.equal(f.calls[0].options.headers.Authorization, `Bearer ${ACCESS}`);
  assert.equal(f.calls[0].options.headers['Content-Type'], undefined);
  assert.equal(f.calls[0].options.body, undefined);
});

test('auth client sanitizes oversized profile fields and unsafe avatar URLs', async () => {
  for (const avatar_url of [
    'javascript:alert(1)', 'http://images.example/avatar.png', 'https://person:secret@images.example/avatar.png',
    '/relative.png', `https://images.example/${'x'.repeat(2048)}`, null,
  ]) {
    const f = fixture(() => response({ ...profile(), email: 'e'.repeat(321), user_metadata: { full_name: 'n'.repeat(201), name: 'must-not-replace-invalid-preferred-name', avatar_url } }));
    assert.deepEqual(await f.client.getUser(ACCESS), { id: USER_ID, email: null, name: null, avatarURL: null });
  }
  const f = fixture(() => response({ ...profile(), email: 'e'.repeat(320), user_metadata: { full_name: 'n'.repeat(200), avatar_url: 'https://images.example/avatar.png' } }));
  const result = await f.client.getUser(ACCESS);
  assert.equal(result.email.length, 320);
  assert.equal(result.name.length, 200);
  assert.equal(result.avatarURL, 'https://images.example/avatar.png');
});

test('auth client classifies HTTP and transport failures without exposing response details', async () => {
  for (const [status, code] of [[400, 'authentication'], [401, 'authentication'], [403, 'authentication'], [429, 'connection'], [500, 'connection'], [503, 'connection']]) {
    const f = fixture(() => new Response('private-server-details', { status }));
    await assert.rejects(f.client.getUser(ACCESS), error => authCode(code)(error) && !error.message.includes('private-server-details'));
    assert.deepEqual(f.cancelled, f.timers);
  }
  const f = fixture(() => { throw new TypeError('private-network-details'); });
  await assert.rejects(f.client.getUser(ACCESS), error => authCode('connection')(error) && !error.message.includes('private-network-details'));
  assert.equal(AuthError, PublicAuthError);
});

test('auth client rejects malformed JSON and nonobject response roots', async () => {
  for (const text of ['{broken', 'null', '[]', 'true', '42', '"text"']) {
    const f = fixture(() => new Response(text));
    await assert.rejects(f.client.getUser(ACCESS), authCode('authentication'));
    assert.deepEqual(f.cancelled, f.timers);
  }
});

test('auth client accepts the exact streamed byte limit and cancels oversized responses', async () => {
  const base = JSON.stringify({ ...profile(), padding: '' });
  for (const length of [65_536, 65_537]) {
    const text = JSON.stringify({ ...profile(), padding: 'x'.repeat(length - new TextEncoder().encode(base).byteLength) });
    const bytes = new TextEncoder().encode(text);
    assert.equal(bytes.byteLength, length);
    const stream = streamed([bytes.subarray(0, 30_000), bytes.subarray(30_000)]);
    const f = fixture(() => stream.response);
    if (length === 65_536) assert.equal((await f.client.getUser(ACCESS)).id, USER_ID);
    else await assert.rejects(f.client.getUser(ACCESS), authCode('authentication'));
    assert.equal(stream.state.cancelled, length > 65_536);
    assert.equal(stream.state.released, true);
    assert.deepEqual(f.cancelled, f.timers);
  }
});

test('auth client measures nonstream response size in UTF-8 bytes', async () => {
  const valid = JSON.stringify(profile());
  const oversized = JSON.stringify({ ...profile(), padding: '한'.repeat(22_000) });
  assert.ok(oversized.length < 65_536);
  assert.ok(new TextEncoder().encode(oversized).byteLength > 65_536);
  const accepted = fixture(() => ({ ok: true, text: async () => valid }));
  assert.equal((await accepted.client.getUser(ACCESS)).id, USER_ID);
  const rejected = fixture(() => ({ ok: true, text: async () => oversized }));
  await assert.rejects(rejected.client.getUser(ACCESS), authCode('authentication'));
});

test('auth client preserves split UTF-8 characters and releases malformed streams', async () => {
  const bytes = new TextEncoder().encode(JSON.stringify({ ...profile(), user_metadata: { full_name: '엄마' } }));
  const split = bytes.findIndex(byte => byte >= 0x80) + 1;
  const valid = streamed([bytes.subarray(0, split), bytes.subarray(split)]);
  assert.equal((await fixture(() => valid.response).client.getUser(ACCESS)).name, '엄마');
  assert.equal(valid.state.released, true);
  const malformed = streamed([new Uint8Array([0xc3, 0x28])]);
  await assert.rejects(fixture(() => malformed.response).client.getUser(ACCESS), authCode('connection'));
  assert.equal(malformed.state.released, true);
});

test('auth client timeout aborts its request and clears the timer', async () => {
  let signal;
  const f = fixture((_url, options) => new Promise((_resolve, reject) => {
    signal = options.signal;
    signal.addEventListener('abort', () => reject(new DOMException('timed out', 'AbortError')), { once: true });
  }));
  const pending = f.client.getUser(ACCESS);
  const rejected = assert.rejects(pending, authCode('connection'));
  assert.equal(f.timers[0].delay, 20_000);
  assert.equal(signal.aborted, false);
  f.timers[0].callback();
  await rejected;
  assert.equal(signal.aborted, true);
  assert.deepEqual(f.cancelled, f.timers);
});

test('auth client logout revokes only the local session and accepts an empty success', async () => {
  const f = fixture(() => ({ ok: true, get body() { throw new Error('logout must not read response data'); } }));
  assert.equal(await f.client.signOut(ACCESS), null);
  assert.equal(f.calls[0].url, `${SUPABASE_URL}/auth/v1/logout?scope=local`);
  assert.equal(f.calls[0].options.method, 'POST');
  assert.equal(f.calls[0].options.headers.Authorization, `Bearer ${ACCESS}`);
  assert.deepEqual(JSON.parse(f.calls[0].options.body), {});
  assert.deepEqual(f.cancelled, f.timers);
});
