import { test } from 'node:test';
import assert from 'node:assert/strict';
import { generateDevice, unwrapRecordKey, RecordError } from '../web/record-crypto.js';
import { transcriptPayload } from '../web/transcript-protocol.js';

const T = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';

test('record unwrap stays decrypt-only for ledger keys', async () => {
  const f = { workspaceID: T, keyID: T, wrapped: 'A'.repeat(124), device: await generateDevice(T) };
  await assert.rejects(unwrapRecordKey(f), error => error instanceof RecordError);
  const device = await generateDevice(T);
  assert.deepEqual(device.privateKey.usages, ['deriveBits']);
});

test('transcript payload rejects roles and parts the server will not store', () => {
  assert.deepEqual(transcriptPayload({ id: T, role: 'user', parts: [{ type: 'text', text: '카드값' }] }).parts[0].text, '카드값');
  assert.throws(() => transcriptPayload({ id: T, role: 'system', parts: [{ type: 'text', text: 'x' }] }), error => error instanceof RecordError);
  assert.throws(() => transcriptPayload({ id: T, role: 'user', parts: [{ type: 'tool' }] }), error => error instanceof RecordError);
});
