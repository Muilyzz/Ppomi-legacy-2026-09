import { test } from 'node:test';
import assert from 'node:assert/strict';
import { webcrypto } from 'node:crypto';
import { createTranscriptSession } from '../web/transcript-session.js';
import { createTranscriptClient } from '../web/transcript-client.js';
import { createTranscriptRealtime } from '../web/transcript-realtime.js';
import { realtimeTurnSignal, transcriptList, transcriptPayload, transcriptTurnPage } from '../web/transcript-protocol.js';
import { generateDevice, RecordError } from '../web/record-crypto.js';

const T = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
const W = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb';
const U = 'cccccccc-cccc-4ccc-8ccc-cccccccccccc';

test('transcript protocol accepts list metadata and stored turn payloads', () => {
  const listed = transcriptList({
    transcripts: [{
      id: T, workspace_id: W, created_by_user_id: U, created_at: 't', updated_at: 't', last_seq: 0,
    }],
  });
  assert.equal(listed[0].lastSeq, '0');
  const page = transcriptTurnPage({
    found: true, transcript_id: T, workspace_id: W,
    turns: [{ turn_id: T, seq: 1, writer_user_id: U,
      payload: { id: T, role: 'user', parts: [{ type: 'text', text: '카드값' }] } }],
  }, T);
  assert.equal(page.turns[0].payload.parts[0].text, '카드값');
  assert.throws(() => transcriptPayload({ id: T, role: 'system', parts: [] }), error => error instanceof RecordError);
  const signal = realtimeTurnSignal({
    workspace_id: W, transcript_id: T, turn_id: T, seq: 2,
    envelope: { version: 1, nonce: 'x', ciphertext: 'y', tag: 'z' },
  });
  assert.equal(signal.wiped, false);
  assert.equal(signal.seq, '2');
});

test('transcript session hydrates, appends, and forwards remote turns without exposing a client', async () => {
  const events = [];
  let listener;
  const client = {
    async load() { return { status: 'ready', transcript: { id: T }, turns: [{ id: T, role: 'user', parts: [{ type: 'text', text: 'hi' }] }] }; },
    async append(turn) { return { ...turn, seq: '2' }; },
    subscribe(fn) { listener = fn; return () => { listener = undefined; }; },
    async startRealtime() { events.push('realtime'); },
    dispose() { events.push('dispose'); },
    async clearPrivate() { events.push('clear'); },
  };
  const session = createTranscriptSession({ createClient: () => client });
  const seen = [];
  session.watch(event => seen.push(event.type));
  await session.start({ id: W });
  assert.equal(session.getState().turns[0].text ?? session.getState().turns[0].parts[0].text, 'hi');
  assert.deepEqual(events, ['realtime']);
  await session.append({ id: 'dddddddd-dddd-4ddd-8ddd-dddddddddddd', role: 'assistant', parts: [{ type: 'text', text: '네' }] });
  listener({ type: 'turn', turn: { id: 'eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee', role: 'assistant', parts: [{ type: 'text', text: '원격' }] } });
  assert.equal(session.getState().turns.length, 3);
  assert.deepEqual(seen, ['turn', 'turn']);
  await session.clearPrivate(W);
  assert.deepEqual(events.slice(-2), ['dispose', 'clear']);
  assert.equal(session.getState().status, 'idle');
});

test('realtime client joins postgres_changes and forwards ciphertext as a refetch signal', async () => {
  const sockets = [];
  class FakeSocket {
    constructor(url) { this.url = url; this.readyState = 1; this.handlers = {}; sockets.push(this); queueMicrotask(() => this.handlers.open?.({})); }
    addEventListener(type, fn) { this.handlers[type] = fn; }
    send(raw) { this.sent = [...this.sent ?? [], JSON.parse(raw)]; }
    close() { this.readyState = 3; this.handlers.close?.({}); }
  }
  FakeSocket.OPEN = 1;
  const events = [];
  const realtime = createTranscriptRealtime({
    getAccessToken: async () => 'header.payload.signature',
    WebSocket: FakeSocket,
    onEvent: event => events.push(event.type),
    setTimeout: () => 1, clearTimeout: () => {},
  });
  await realtime.start();
  assert.match(sockets[0].url, /realtime\/v1\/websocket/);
  const join = sockets[0].sent.find(item => item.event === 'phx_join');
  assert.equal(join.payload.config.postgres_changes.some(item => item.table === 'ppomi_transcript_turns'), true);
  sockets[0].handlers.message({ data: JSON.stringify({
    event: 'postgres_changes',
    payload: { data: { type: 'INSERT', table: 'ppomi_transcript_turns',
      record: { workspace_id: W, transcript_id: T, turn_id: T, seq: 1,
        envelope: { version: 1, nonce: 'AAAAAAAAAAAAAAAAAAAAAA', tag: 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA', ciphertext: 'dGVzdA' } } } },
  }) });
  assert.deepEqual(events, ['turn']);
  realtime.stop();
});

test('transcript client treats Realtime ciphertext as a signal and decrypts via RPC', async () => {
  const device = await generateDevice(U, webcrypto);
  const calls = [];
  let onRealtimeEvent;
  const response = value => new Response(JSON.stringify(value), { headers: { 'Content-Type': 'application/json' } });
  const context = {
    workspace: { id: W, name: 'Synthetic' },
    device: { id: device.deviceID, label: '브라우저', platform: 'web' },
  };
  const turnPage = {
    found: true, transcript_id: T, workspace_id: W,
    turns: [{
      turn_id: T, seq: 2, writer_user_id: U,
      payload: { id: T, role: 'assistant', parts: [{ type: 'text', text: '원격' }] },
    }],
  };
  const client = createTranscriptClient({
    auth: { getUser: () => ({ id: U }), getAccessToken: async () => 'synthetic-access-token' },
    user: { id: U },
    crypto: webcrypto,
    deviceStore: { loadOrCreate: async () => device, clear: async () => {} },
    realtime: ({ onEvent }) => {
      onRealtimeEvent = onEvent;
      return { start: async () => {}, stop: () => {} };
    },
    fetch: async url => {
      const name = String(url).split('/').at(-1);
      calls.push(name);
      if (name === 'ppomi_register_device' || name === 'ppomi_context') return response(context);
      if (name === 'ppomi_transcript_list') {
        return response({
          transcripts: [{
            id: T, workspace_id: W, created_by_user_id: U,
            created_at: 't', updated_at: 't', last_seq: 1,
          }],
        });
      }
      if (name === 'ppomi_transcript_turns') return response(turnPage);
      throw new Error(`unexpected ${name}`);
    },
  });
  const loaded = await client.load();
  assert.equal(loaded.turns[0].parts[0].text, '원격');
  const seen = [];
  client.subscribe(event => seen.push(event));
  await client.startRealtime();
  await onRealtimeEvent({
    type: 'turn',
    record: {
      workspace_id: W, transcript_id: T, turn_id: T, seq: 2,
      envelope: {
        version: 1, nonce: 'AAAAAAAAAAAAAAAAAAAAAA',
        tag: 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA', ciphertext: 'dGVzdA',
      },
    },
  });
  assert.ok(calls.filter(name => name === 'ppomi_transcript_turns').length >= 2);
  assert.equal(seen[0].type, 'turn');
  assert.equal(seen[0].turn.parts[0].text, '원격');
  assert.ok(!JSON.stringify(seen).includes('dGVzdA'));
  client.dispose();
});
