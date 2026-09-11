#!/usr/bin/env node
// Explicit regeneration for cross-platform unit tests only. Never a production release/signing key.
import { createHash, generateKeyPairSync } from 'node:crypto';
import { mkdir, writeFile } from 'node:fs/promises';
import path from 'node:path';
import { CAPABILITIES, REQUIRED, ROOT, encodePackage, rawPublicKey } from './family-update.mjs';

if (process.argv.slice(2).join(' ') !== '--write-test-fixtures') throw new Error('Explicit test-only command: node scripts/family-update-fixtures.mjs --write-test-fixtures');
const directory = path.join(ROOT, 'tests/updates');
await mkdir(directory, { recursive: true });
const { privateKey } = generateKeyPairSync('ec', { namedCurve: 'prime256v1' });
await writeFile(path.join(directory, 'public-key.txt'), rawPublicKey(privateKey) + '\n');
for (const platform of Object.keys(CAPABILITIES)) {
  const files = REQUIRED[platform].map(name => {
    const bytes = Buffer.from(`TEST ONLY fixture: ${name}\n`);
    return { path: name, sha256: createHash('sha256').update(bytes).digest('hex'), data: bytes.toString('base64') };
  });
  const payload = { formatVersion: 1, release: 'fixture-test-only', sequence: 42, channel: 'preview', platform, bridgeVersion: 1, minNativeBuild: 1, capabilities: CAPABILITIES[platform], files };
  const envelope = encodePackage(payload, privateKey);
  await writeFile(path.join(directory, `valid-${platform}.json`), envelope);
  if (platform === 'macos') {
    const broken = JSON.parse(envelope), bytes = Buffer.from(broken.payload, 'base64');
    bytes[10] ^= 1; broken.payload = bytes.toString('base64');
    await writeFile(path.join(directory, 'tampered.json'), JSON.stringify(broken));
  }
}
process.stdout.write('Regenerated tests/updates TEST ONLY fixtures; ephemeral private key discarded.\n');
