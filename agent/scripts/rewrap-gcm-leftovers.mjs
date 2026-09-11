// One-shot leftover AES-GCM → at-rest rewrap. Run as a workspace member
// after slice 4, then drop PPOMI_AGENT_MEMORY_KEY from the deployment.
// The live agent handler no longer decrypts GCM.
import { createDecipheriv } from 'node:crypto';
import { pathToFileURL } from 'node:url';

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

export function memoryKey(raw) {
  if (!/^[A-Za-z0-9+/]{43}=$/.test(raw ?? '')) throw new Error('PPOMI_AGENT_MEMORY_KEY must be 32 canonical base64 bytes');
  const key = Buffer.from(raw, 'base64');
  if (key.length !== 32 || key.toString('base64') !== raw) throw new Error('PPOMI_AGENT_MEMORY_KEY must be 32 canonical base64 bytes');
  return key;
}

export function isLegacyGcmRow(row) {
  const envelope = row?.envelope;
  return Boolean(envelope && envelope.version === 1
    && typeof envelope.nonce === 'string' && /^[A-Za-z0-9_-]{16}$/.test(envelope.nonce)
    && typeof envelope.tag === 'string' && /^[A-Za-z0-9_-]{22}$/.test(envelope.tag)
    && typeof envelope.ciphertext === 'string'
    && (!row.payload || typeof row.payload !== 'object' || Array.isArray(row.payload)));
}

export function decryptLegacyGcm(row, workspace, key) {
  if (!isLegacyGcmRow(row) || row.workspace_id !== workspace || !UUID.test(row.id) || row.deleted_at) {
    throw new Error('not a leftover GCM row');
  }
  const binding = Buffer.from(JSON.stringify(['ppomi-agent-memory', 1, workspace, row.id, row.replaces_id ?? null]));
  const decipher = createDecipheriv('aes-256-gcm', key, Buffer.from(row.envelope.nonce, 'base64url'));
  decipher.setAAD(binding);
  decipher.setAuthTag(Buffer.from(row.envelope.tag, 'base64url'));
  const payload = JSON.parse(Buffer.concat([
    decipher.update(Buffer.from(row.envelope.ciphertext, 'base64url')),
    decipher.final(),
  ]).toString('utf8'));
  return {
    id: payload.id,
    kind: payload.kind,
    text: payload.text,
    source: payload.source,
    confidence: payload.confidence,
    replacesId: payload.replacesId ?? null,
    selection: 'automatic',
  };
}

async function rpc(env, name, body) {
  const response = await fetch(`${env.SUPABASE_URL}/rest/v1/rpc/${name}`, {
    method: 'POST',
    redirect: 'error',
    headers: {
      apikey: env.SUPABASE_ANON_KEY,
      Authorization: `Bearer ${env.PPOMI_ACCESS_TOKEN}`,
      'Content-Type': 'application/json',
    },
    body: JSON.stringify(body),
    cache: 'no-store',
  });
  if (!response.ok) throw new Error(`${name} failed (${response.status})`);
  return response.json();
}

export async function rewrapLeftovers(env, transport = rpc) {
  const key = memoryKey(env.PPOMI_AGENT_MEMORY_KEY);
  const context = await transport(env, 'ppomi_context', {});
  const workspace = context?.workspace?.id;
  if (!UUID.test(workspace ?? '')) throw new Error('workspace membership required');
  const rows = await transport(env, 'ppomi_agent_memory_list', {});
  if (!Array.isArray(rows)) throw new Error('memory list must be an array');
  let rewritten = 0;
  for (const row of rows) {
    if (!isLegacyGcmRow(row)) continue;
    const payload = decryptLegacyGcm(row, workspace, key);
    await transport(env, 'ppomi_agent_memory_rewrap', { p_id: row.id, p_payload: payload });
    rewritten += 1;
  }
  return { leftover: rewritten, workspace };
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  const result = await rewrapLeftovers(process.env);
  console.log(`rewrapped ${result.leftover} leftover GCM rows in ${result.workspace}`);
}
