import assert from 'node:assert/strict';
import test from 'node:test';
import { createCipheriv, randomBytes } from 'node:crypto';
import { decryptLegacyGcm, isLegacyGcmRow, rewrapLeftovers } from './rewrap-gcm-leftovers.mjs';

const WORKSPACE = 'aaaaaaaa-1111-4111-8111-111111111111';
const ID = 'bbbbbbbb-1111-4111-8111-111111111111';

function gcmRow(key, text = '옛 GCM 기록이다.') {
  const payload = { id: ID, kind: 'fact', text, source: 'tool_observed', confidence: 1, replacesId: null, selection: 'automatic' };
  const binding = Buffer.from(JSON.stringify(['ppomi-agent-memory', 1, WORKSPACE, ID, null]));
  const nonce = randomBytes(12), cipher = createCipheriv('aes-256-gcm', key, nonce);
  cipher.setAAD(binding);
  const encrypted = Buffer.concat([cipher.update(JSON.stringify(payload), 'utf8'), cipher.final()]);
  return {
    id: ID, workspace_id: WORKSPACE, replaces_id: null, created_at: '2026-09-09T13:00:00Z', deleted_at: null,
    envelope: { version: 1, nonce: nonce.toString('base64url'), ciphertext: encrypted.toString('base64url'), tag: cipher.getAuthTag().toString('base64url') },
  };
}

test('leftover GCM rows decrypt and rewrap; at-rest payload rows are left alone', async () => {
  const key = randomBytes(32);
  const env = {
    PPOMI_AGENT_MEMORY_KEY: key.toString('base64'),
    SUPABASE_URL: 'https://abcdefghijklmnopqrst.supabase.co',
    SUPABASE_ANON_KEY: 'sb_publishable_test',
    PPOMI_ACCESS_TOKEN: 'test.device.signature',
  };
  const leftover = gcmRow(key);
  const opened = { id: ID, workspace_id: WORKSPACE, payload: { text: 'already-open' } };
  assert.equal(isLegacyGcmRow(leftover), true);
  assert.equal(isLegacyGcmRow(opened), false);
  assert.equal(decryptLegacyGcm(leftover, WORKSPACE, key).text, '옛 GCM 기록이다.');
  const calls = [];
  const result = await rewrapLeftovers(env, async (_env, name, body) => {
    calls.push({ name, body });
    if (name === 'ppomi_context') return { workspace: { id: WORKSPACE }, device: { id: ID } };
    if (name === 'ppomi_agent_memory_list') return [leftover, opened];
    if (name === 'ppomi_agent_memory_rewrap') return { payload: body.p_payload };
    throw new Error(name);
  });
  assert.equal(result.leftover, 1);
  assert.equal(calls.filter(call => call.name === 'ppomi_agent_memory_rewrap').length, 1);
  assert.equal(calls.find(call => call.name === 'ppomi_agent_memory_rewrap')?.body.p_payload.text, '옛 GCM 기록이다.');
});
