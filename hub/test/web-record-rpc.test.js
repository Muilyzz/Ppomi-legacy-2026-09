import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createRecordRPC } from '../web/record-rpc.js';
import { RecordError } from '../web/record-crypto.js';
import { SUPABASE_URL, PUBLISHABLE_KEY } from '../web/config.js';

const bytes = text => new TextEncoder().encode(text);
const rejectsWith = (promise, code) => assert.rejects(promise, error => error instanceof RecordError && error.code === code);
function deferred() {
  let resolve;
  const promise = new Promise(done => { resolve = done; });
  return { promise, resolve };
}
function setup(options = {}) {
  const lifetime = new AbortController();
  let owner = 'account-a';
  const rpc = createRecordRPC({
    auth: { getAccessToken: async () => 'synthetic-token' },
    check: () => { if (owner !== 'account-a') throw new RecordError('cancelled'); },
    getDeviceID: () => 'synthetic-browser-device', signal: lifetime.signal,
    fetch: async () => new Response('{"found":true}'), ...options,
  });
  return { rpc, lifetime, changeAccount: () => { owner = 'account-b'; } };
}
function streamResponse(parts) {
  const stats = { cancelled: false, released: false };
  let index = 0;
  return {
    stats,
    response: { ok: true, status: 200, body: { getReader: () => ({
      read: async () => index < parts.length ? { done: false, value: parts[index++] } : { done: true },
      cancel: async () => { stats.cancelled = true; },
      releaseLock: () => { stats.released = true; },
    }) } },
  };
}

test('RPC binds the request to its token and device without ambient credentials, preserving exact JSON integers', async () => {
  let request;
  const encoded = bytes('{"version":9223372036854775807,"label":"뽀미"}');
  // Split every UTF-8 character across chunks as a real network stream may do.
  const stream = streamResponse(Array.from(encoded, byte => Uint8Array.of(byte)));
  const { rpc } = setup({ fetch: async (url, init) => { request = { url, init }; return stream.response; } });
  const value = await rpc('ppomi_record_get', { p_record_id: 'synthetic-record' });
  assert.equal(value.version, 9223372036854775807n);
  assert.equal(value.label, '뽀미');
  assert.equal(request.url, `${SUPABASE_URL}/rest/v1/rpc/ppomi_record_get`);
  const { init } = request;
  assert.equal(init.method, 'POST');
  assert.deepEqual(JSON.parse(init.body), { p_record_id: 'synthetic-record' });
  const headers = new Headers(init.headers);
  assert.equal(headers.get('authorization'), 'Bearer synthetic-token');
  assert.equal(headers.get('apikey'), PUBLISHABLE_KEY);
  assert.equal(headers.get('x-ppomi-device'), 'synthetic-browser-device');
  assert.equal(headers.get('content-type'), 'application/json');
  assert.equal(headers.get('accept'), 'application/json');
  assert.equal(init.credentials, 'omit');
  assert.equal(init.redirect, 'error');
  assert.equal(init.cache, 'no-store');
  assert.equal(init.referrerPolicy, 'no-referrer');
  assert.equal(stream.stats.released, true);
});

test('account changes while obtaining a token prevent the request from being sent', async () => {
  const token = deferred();
  let requests = 0;
  const e = setup({ auth: { getAccessToken: () => token.promise }, fetch: async () => { requests++; return new Response('{}'); } });
  const pending = e.rpc('ppomi_context', {});
  const rejected = rejectsWith(pending, 'cancelled');
  e.changeAccount(); token.resolve('old-account-token');
  await rejected;
  assert.equal(requests, 0);
});

test('a response received after an account change cannot become a usable result', async () => {
  const fetched = deferred(), entered = deferred();
  let bodyReads = 0;
  const e = setup({ fetch: () => { entered.resolve(); return fetched.promise; } });
  const pending = e.rpc('ppomi_context', {});
  const rejected = rejectsWith(pending, 'cancelled');
  await entered.promise;
  e.changeAccount();
  fetched.resolve({ ok: true, status: 200, body: { getReader: () => { bodyReads++; throw new Error('Must not read another account response'); } } });
  await rejected;
  assert.equal(bodyReads, 0);
});

test('account changes during a streamed response discard the pending body and release its reader', async () => {
  const part = deferred(), entered = deferred();
  let released = false;
  const e = setup({ fetch: async () => ({ ok: true, status: 200, body: { getReader: () => ({
    read: () => { entered.resolve(); return part.promise; }, releaseLock: () => { released = true; },
  }) } }) });
  const pending = e.rpc('ppomi_record_get', {});
  const rejected = rejectsWith(pending, 'cancelled');
  await entered.promise;
  e.changeAccount(); part.resolve({ done: false, value: bytes('{"private":true}') });
  await rejected;
  assert.equal(released, true);
});

test('parent cancellation stops in-flight requests and pre-cancelled lifetimes perform no authentication or fetch', async () => {
  let tokenReads = 0, requests = 0;
  const e = setup({ auth: { getAccessToken: async () => { tokenReads++; return 'synthetic-token'; } },
    fetch: async () => { requests++; return new Response('{}'); } });
  e.lifetime.abort();
  await rejectsWith(e.rpc('ppomi_context', {}), 'cancelled');
  assert.equal(tokenReads, 0);
  assert.equal(requests, 0);

  const entered = deferred();
  let requestSignal;
  const active = setup({ fetch: (url, { signal }) => {
    requestSignal = signal; entered.resolve();
    return new Promise((resolve, reject) => signal.addEventListener('abort', () => reject(new Error('aborted')), { once: true }));
  } });
  const pending = active.rpc('ppomi_context', {});
  const rejected = rejectsWith(pending, 'cancelled');
  await entered.promise;
  active.lifetime.abort();
  await rejected;
  assert.equal(requestSignal.aborted, true);
});

test('parent cancellation while obtaining a token prevents a later fetch', async () => {
  const token = deferred();
  let requests = 0;
  const e = setup({ auth: { getAccessToken: () => token.promise }, fetch: async () => { requests++; return new Response('{}'); } });
  const pending = e.rpc('ppomi_context', {});
  const rejected = rejectsWith(pending, 'cancelled');
  e.lifetime.abort(); token.resolve('synthetic-token');
  await rejected;
  assert.equal(requests, 0);
});

test('the deadline aborts a stalled request and completed requests leave no active deadline', async t => {
  t.mock.timers.enable({ apis: ['setTimeout'] });
  const entered = deferred();
  let stalledSignal;
  const stalled = setup({ fetch: (url, { signal }) => {
    stalledSignal = signal; entered.resolve();
    return new Promise((resolve, reject) => signal.addEventListener('abort', () => reject(new Error('deadline')), { once: true }));
  } });
  const pending = stalled.rpc('ppomi_context', {});
  const rejected = rejectsWith(pending, 'connection');
  await entered.promise;
  t.mock.timers.tick(19_999);
  assert.equal(stalledSignal.aborted, false);
  t.mock.timers.tick(1);
  await rejected;
  assert.equal(stalledSignal.aborted, true);

  let completedSignal;
  const completed = setup({ fetch: async (url, { signal }) => { completedSignal = signal; return new Response('{}'); } });
  await completed.rpc('ppomi_context', {});
  t.mock.timers.tick(20_000);
  completed.lifetime.abort();
  assert.equal(completedSignal.aborted, false, 'successful requests release both the timer and parent abort listener');
});

test('streamed responses accept each byte limit and cancel the reader immediately above it', async () => {
  for (const [name, limit] of [['ppomi_record_get', 128_000], ['ppomi_record_blob_get', 600_000]]) {
    for (const excess of [0, 1]) {
      const payload = bytes('{"data":"' + 'a'.repeat(limit - 11 + excess) + '"}');
      assert.equal(payload.byteLength, limit + excess);
      const stream = streamResponse([payload.subarray(0, limit - 1), payload.subarray(limit - 1)]);
      const { rpc } = setup({ fetch: async () => stream.response });
      if (excess) await rejectsWith(rpc(name, {}), 'invalid');
      else assert.equal((await rpc(name, {})).data.length, limit - 11);
      assert.equal(stream.stats.cancelled, Boolean(excess));
      assert.equal(stream.stats.released, true);
    }
  }
});

test('HTTP failures retain actionable authentication and permission errors', async () => {
  for (const [status, code] of [[401, 'authentication'], [403, 'permission'], [404, 'connection'], [500, 'connection']]) {
    const { rpc } = setup({ fetch: async () => new Response('{}', { status }) });
    await rejectsWith(rpc('ppomi_context', {}), code);
  }
});

test('missing bodies and non-object or malformed JSON cannot become record metadata', async () => {
  for (const response of [new Response(null), ...['null', '[]', '42', '"text"', '{broken'].map(text => new Response(text))]) {
    const { rpc } = setup({ fetch: async () => response });
    await rejectsWith(rpc('ppomi_record_get', {}), 'invalid');
  }
});

test('network and invalid UTF-8 failures become connection errors and release opened readers', async () => {
  const network = setup({ fetch: async () => { throw new TypeError('network unavailable'); } });
  await rejectsWith(network.rpc('ppomi_context', {}), 'connection');
  for (const invalid of [Uint8Array.of(0xff), Uint8Array.of(0xe2, 0x82)]) {
    const stream = streamResponse([bytes('{"data":"'), invalid]);
    const { rpc } = setup({ fetch: async () => stream.response });
    await rejectsWith(rpc('ppomi_record_get', {}), 'connection');
    assert.equal(stream.stats.released, true);
  }
});
