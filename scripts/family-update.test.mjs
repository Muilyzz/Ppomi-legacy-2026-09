import test from 'node:test';
import assert from 'node:assert/strict';
import { createHash, generateKeyPairSync, sign } from 'node:crypto';
import { mkdtemp, mkdir, readFile, rm, symlink, writeFile } from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { CAPABILITIES, LIMITS, REQUIRED, encodePackage, rawPublicKey, repositoryFiles, validateConfig, validatePath, validatePayload, verifyPackage } from './family-update.mjs';

const { privateKey } = generateKeyPairSync('ec', { namedCurve: 'prime256v1' });
const publicKey = rawPublicKey(privateKey);
const file = (path, data = Buffer.from('fixture')) => ({ path, sha256: createHash('sha256').update(data).digest('hex'), data: data.toString('base64') });
function payload(platform = 'macos') {
  return { formatVersion: 1, release: 'test-1', sequence: 1, channel: 'preview', platform, bridgeVersion: 1, minNativeBuild: 1,
    capabilities: [...CAPABILITIES[platform]], files: REQUIRED[platform].map(name => file(name)) };
}
function signedUnchecked(value) {
  const bytes = Buffer.from(JSON.stringify(value));
  return Buffer.from(JSON.stringify({ payload: bytes.toString('base64'), signature: sign('sha256', bytes, privateKey).toString('base64') }));
}
for (const platform of Object.keys(CAPABILITIES)) test(`real DER signature and exact payload round trip: ${platform}`, () => {
  assert.deepEqual(verifyPackage(encodePackage(payload(platform), privateKey), publicKey, { platform, channel: 'preview', afterSequence: 0 }), payload(platform));
});
test('tamper, wrong key, replay and platform/channel confusion fail closed', () => {
  const pkg = encodePackage(payload(), privateKey), altered = JSON.parse(pkg);
  const bytes = Buffer.from(altered.payload, 'base64'); bytes[4] ^= 1; altered.payload = bytes.toString('base64');
  assert.throws(() => verifyPackage(Buffer.from(JSON.stringify(altered)), publicKey), /signature/);
  const other = generateKeyPairSync('ec', { namedCurve: 'prime256v1' });
  assert.throws(() => verifyPackage(pkg, rawPublicKey(other.privateKey)), /signature/);
  assert.throws(() => verifyPackage(pkg, publicKey, { afterSequence: 1 }), /replayed/);
  assert.throws(() => verifyPackage(pkg, publicKey, { platform: 'ipados' }), /platform mismatch/);
  assert.throws(() => verifyPackage(pkg, publicKey, { channel: 'family' }), /channel mismatch/);
});
test('rejects unsigned envelope extensions, broken base64 and non-UTF8 payloads', () => {
  const wrapper = JSON.parse(encodePackage(payload(), privateKey));
  assert.throws(() => verifyPackage(JSON.stringify({ ...wrapper, endpoint: 'https://example.com' }), publicKey), /fields/);
  assert.throws(() => verifyPackage(JSON.stringify({ ...wrapper, payload: wrapper.payload + '\n' }), publicKey), /base64/);
  const bytes = Buffer.from([0xff]);
  assert.throws(() => verifyPackage(JSON.stringify({ payload: bytes.toString('base64'), signature: sign('sha256', bytes, privateKey).toString('base64') }), publicKey), /encoded data/);
});
test('valid signature cannot authorize invalid paths or file aliases', () => {
  for (const bad of ['../app.js', '/app.js', 'Agent/../app.js', 'Agent\\app.js', 'Agent/%61pp.js', 'app.js?x', 'app.js#x', 'Agent//app.js', '.hidden.js', 'a/./app.js', 'é.js', 'payload.dylib']) {
    const p = payload(); p.files.push(file(bad));
    assert.throws(() => verifyPackage(signedUnchecked(p), publicKey), /path|extension/, bad);
  }
  const duplicate = payload(); duplicate.files.push(file('agent/APP.js'));
  assert.throws(() => verifyPackage(signedUnchecked(duplicate), publicKey), /duplicate/);
  const collision = payload(); collision.files.push(file('Agent/app.js/nested.css'));
  assert.throws(() => verifyPackage(signedUnchecked(collision), publicKey), /collision/);
  validatePath('Agent/fonts/font-1.woff2');
});
test('valid signature cannot change schema or invent capabilities', () => {
  for (const change of [p => { p.extra = true; }, p => { p.formatVersion = 2; }, p => { p.sequence = 0; }, p => { p.sequence = 2147483648; },
    p => { p.sequence = 1.5; }, p => { p.release = '../test'; }, p => { p.bridgeVersion = 2; }, p => { p.minNativeBuild = 2; },
    p => { p.capabilities = ['agent.v1', 'tools.admin']; }, p => { p.capabilities = ['agent.v1', 'agent.v1']; },
    p => { p.files.pop(); }, p => { p.files[0].sha256 = '0'.repeat(64); }, p => { p.files[0].extra = true; }]) {
    const p = payload(); change(p); assert.throws(() => verifyPackage(signedUnchecked(p), publicKey));
  }
});
test('file count, per-file, aggregate and outer limits are enforced', () => {
  const tooMany = payload(); tooMany.files.push(...Array.from({ length: LIMITS.files }, (_, i) => file(`file-${i}.js`)));
  assert.throws(() => validatePayload(tooMany), /file count/);
  const tooBig = payload(); tooBig.files.push(file('big.js', Buffer.alloc(LIMITS.fileBytes + 1)));
  assert.throws(() => validatePayload(tooBig), /too large/);
  const aggregate = payload(); aggregate.files.push(file('big-a.js', Buffer.alloc(LIMITS.fileBytes)), file('big-b.js', Buffer.alloc(LIMITS.fileBytes)));
  assert.throws(() => validatePayload(aggregate), /too large/);
  assert.throws(() => verifyPackage(Buffer.alloc(LIMITS.envelopeBytes + 1), publicKey), /envelope too large/);
});
test('only pinned native config with the documented HTTPS endpoint is valid', () => {
  const config = { formatVersion: 1, endpoint: 'https://updates.example.org/preview/macos.json', publicKey, channel: 'preview' };
  assert.deepEqual(validateConfig(config), config);
  for (const endpoint of ['http://updates.example.org/preview/macos.json', 'https://user:pass@example.org/preview/macos.json', 'https://example.org/preview/macos.json?q=1', 'https://example.org/family/macos.json']) {
    assert.throws(() => validateConfig({ ...config, endpoint }));
  }
  assert.throws(() => validateConfig({ ...config, fallbackKey: publicKey }), /fields/);
});
test('publisher reads only reviewed static roots, requires a generated agent and rejects symlinks', async () => {
  const root = await mkdtemp(path.join(os.tmpdir(), 'ppomi-release-input-'));
  try {
    const web = path.join(root, 'Ppomi/Sources/Ppomi/Web');
    await mkdir(path.join(web, 'Agent'), { recursive: true });
    await mkdir(path.join(root, 'agent/src/generated'), { recursive: true });
    await mkdir(path.join(root, 'iPad/Web'), { recursive: true });
    await writeFile(path.join(web, 'Agent/index.html'), 'Content-Security-Policy ./app.js ./app.css');
    await writeFile(path.join(web, 'Agent/app.css'), 'body{}'.repeat(20));
    await writeFile(path.join(web, 'Agent/app.js'), 'placeholder');
    await writeFile(path.join(root, 'agent/src/generated/playbooks.json'), JSON.stringify({ schemaVersion: 1, playbooks: [] }));
    await assert.rejects(repositoryFiles('macos', root), /build agent first/);
    await writeFile(path.join(web, 'Agent/app.js'), 'updateReady');
    await writeFile(path.join(web, 'pad.html'), 'shared');
    await writeFile(path.join(root, 'iPad/Web/pad.html'), 'iPad override');
    await writeFile(path.join(web, 'secret.pem'), 'never include');
    await writeFile(path.join(root, 'private-record.json'), 'never include');
    const files = await repositoryFiles('ipados', root);
    assert.equal(Buffer.from(files.find(file => file.path === 'pad.html').data, 'base64').toString(), 'iPad override');
    assert.equal(files.some(file => file.path.includes('secret') || file.path.includes('private-record')), false);
    await symlink(path.join(root, 'private-record.json'), path.join(web, 'aliased.json'));
    await assert.rejects(repositoryFiles('macos', root), /symbolic links/);
  } finally { await rm(root, { recursive: true, force: true }); }
});
test('checked-in TEST ONLY fixtures verify with the pinned test public key', async () => {
  const key = (await readFile(new URL('../tests/updates/public-key.txt', import.meta.url), 'utf8')).trim();
  for (const platform of Object.keys(CAPABILITIES)) {
    const p = verifyPackage(await readFile(new URL(`../tests/updates/valid-${platform}.json`, import.meta.url)), key, { platform, channel: 'preview' });
    assert.equal(p.release, 'fixture-test-only');
  }
  assert.throws(() => verifyPackage(JSON.stringify({ payload: '', signature: '' }), key));
  const tampered = await readFile(new URL('../tests/updates/tampered.json', import.meta.url));
  assert.throws(() => verifyPackage(tampered, key), /signature/);
});
