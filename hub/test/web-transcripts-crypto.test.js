import { test } from 'node:test';
import assert from 'node:assert/strict';
import { webcrypto } from 'node:crypto';
import { readFile } from 'node:fs/promises';
import { generateDevice, unwrapRecordKey, RecordError } from '../web/record-crypto.js';
import { base64url, decodeTurnPayload, encodeTurnPayload, openTranscriptTurn, sealTranscriptTurn,
  transcriptAAD, unbase64url } from '../web/transcript-crypto.js';

const f = JSON.parse(await readFile(new URL('./fixtures/web-records-native.json', import.meta.url), 'utf8'));
const fails = code => error => error instanceof RecordError && error.code === code;

async function fixtureKey(usages = ['encrypt', 'decrypt']) {
  const raw = Buffer.from(f.privateKey, 'base64');
  const pkcs8 = Buffer.concat([Buffer.from('302e020100300506032b656e04220420', 'hex'), raw]);
  const privateKey = await webcrypto.subtle.importKey('pkcs8', pkcs8, 'X25519', false, ['deriveBits']);
  const device = { formatVersion: 1, userID: f.userID, deviceID: f.deviceID, privateKey, publicKey: Uint8Array.from(Buffer.from(f.publicKey, 'base64')) };
  return unwrapRecordKey({ ...f, device, usages }, webcrypto);
}

test('transcript envelopes round-trip with the workspace key and bind transcript/turn IDs', async () => {
  const key = await fixtureKey();
  const ids = { workspaceID: f.workspaceID, keyID: f.keyID, transcriptID: 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa', turnID: 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb' };
  const bytes = encodeTurnPayload({ id: ids.turnID, role: 'user', parts: [{ type: 'text', text: '카드값' }] });
  const envelope = await sealTranscriptTurn({ bytes, key, ...ids }, webcrypto);
  assert.equal(envelope.version, 1);
  assert.match(envelope.nonce, /^[A-Za-z0-9_-]{16}$/);
  assert.match(envelope.tag, /^[A-Za-z0-9_-]{22}$/);
  const opened = await openTranscriptTurn({ envelope, key, ...ids }, webcrypto);
  assert.deepEqual(decodeTurnPayload(opened), { id: ids.turnID, role: 'user', parts: [{ type: 'text', text: '카드값' }] });
  assert.doesNotMatch(JSON.stringify(envelope), /카드값/);
  await assert.rejects(openTranscriptTurn({ envelope, key, ...ids, turnID: 'cccccccc-cccc-4ccc-8ccc-cccccccccccc' }, webcrypto), fails('invalid'));
  await assert.rejects(openTranscriptTurn({ envelope, key, ...ids, transcriptID: 'cccccccc-cccc-4ccc-8ccc-cccccccccccc' }, webcrypto), fails('invalid'));
});

test('base64url encoding is canonical and AAD names the transcript version', () => {
  const bytes = Uint8Array.of(0xfb, 0xff, 0xef);
  assert.equal(base64url(bytes), '-__v');
  assert.deepEqual(unbase64url('-__v', 8), bytes);
  assert.throws(() => unbase64url('+//v', 8), fails('invalid'));
  const aad = transcriptAAD({ workspaceID: f.workspaceID, keyID: f.keyID,
    transcriptID: 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa', turnID: 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb' });
  assert.equal(new TextDecoder().decode(aad).startsWith('ppomi-transcript-v1|'), true);
});

test('record unwrap stays decrypt-only unless transcript write usage is requested', async () => {
  const decryptOnly = await fixtureKey(['decrypt']);
  assert.deepEqual(decryptOnly.usages, ['decrypt']);
  const both = await fixtureKey();
  assert.deepEqual([...both.usages].sort(), ['decrypt', 'encrypt']);
  const device = await generateDevice(f.userID, webcrypto);
  await assert.rejects(unwrapRecordKey({ ...f, device, usages: ['sign'] }, webcrypto), fails('invalid'));
});
