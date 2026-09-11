#!/usr/bin/env node
// Restore only the two public, hash-pinned native artifacts listed by the checked-in downloads manifest.
import { createHash } from 'node:crypto';
import { constants, createWriteStream } from 'node:fs';
import { link, lstat, mkdir, mkdtemp, open, realpath, rm, unlink } from 'node:fs/promises';
import https from 'node:https';
import path from 'node:path';
import { Transform } from 'node:stream';
import { pipeline } from 'node:stream/promises';
import { fileURLToPath } from 'node:url';

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const HUB = path.join(ROOT, 'hub');
const RELEASES = path.join(HUB, 'releases');
const ORIGIN = 'https://ppomi.muilyzz.com';
const MAX_ARTIFACT_BYTES = 512 * 1024 * 1024;
const MAX_MANIFEST_BYTES = 16 * 1024;
const assert = (condition, message) => { if (!condition) throw new Error(message); };
function exactKeys(value, expected, label) {
  assert(value && typeof value === 'object' && !Array.isArray(value), `${label}: expected object`);
  assert(Object.keys(value).sort().join(',') === [...expected].sort().join(','), `${label}: missing or unknown fields`);
}
function text(value, maximum) {
  return typeof value === 'string' && value.length > 0 && value.length <= maximum && value.trim() === value && !/[\u0000-\u001f\u007f]/.test(value);
}
export function validateManifest(value) {
  exactKeys(value, ['schemaVersion', 'releases'], 'downloads manifest');
  assert(value.schemaVersion === 1 && Array.isArray(value.releases) && value.releases.length === 2, 'Expected schemaVersion 1 and two native releases');
  const names = new Set(), platforms = new Set();
  for (const release of value.releases) {
    exactKeys(release, ['platform', 'version', 'label', 'filename', 'url', 'bytes', 'sha256', 'requirements', 'notice'], 'release');
    assert(['macos', 'android'].includes(release.platform) && !platforms.has(release.platform), 'Expected one macos and one android release');
    platforms.add(release.platform);
    assert(text(release.version, 64) && /^[0-9]+\.[0-9]+\.[0-9]+(?:-[0-9A-Za-z.-]+)?$/.test(release.version), 'Invalid release version');
    assert(text(release.label, 160) && text(release.requirements, 512) && text(release.notice, 2048), 'Invalid release description');
    assert(text(release.filename, 160) && /^[A-Za-z0-9][A-Za-z0-9._-]*\.(zip|dmg|apk)$/.test(release.filename) && !release.filename.includes('..'), 'Unsafe native artifact filename');
    assert(release.platform === 'android' ? release.filename.endsWith('.apk') : /\.(zip|dmg)$/.test(release.filename), 'Artifact extension does not match platform');
    assert(!names.has(release.filename.toLowerCase()), 'Duplicate native artifact filename'); names.add(release.filename.toLowerCase());
    assert(release.url === `/releases/${release.filename}`, 'Artifact URL must exactly match /releases/<filename>');
    assert(Number.isSafeInteger(release.bytes) && release.bytes > 0 && release.bytes <= MAX_ARTIFACT_BYTES, 'Invalid artifact byte count');
    assert(typeof release.sha256 === 'string' && /^[a-f0-9]{64}$/.test(release.sha256), 'Invalid artifact SHA-256');
  }
  return value;
}
async function directory(location) {
  const info = await lstat(location);
  assert(info.isDirectory() && !info.isSymbolicLink() && await realpath(location) === location, 'Artifact directories must not be symbolic links');
}
async function manifest() {
  await directory(ROOT); await directory(HUB);
  const handle = await open(path.join(HUB, 'downloads.json'), constants.O_RDONLY | constants.O_NOFOLLOW);
  try {
    const info = await handle.stat();
    assert(info.isFile() && info.size <= MAX_MANIFEST_BYTES, 'downloads.json must be a bounded regular file');
    return validateManifest(JSON.parse(new TextDecoder('utf-8', { fatal: true }).decode(await handle.readFile())));
  } finally { await handle.close(); }
}
async function verifyLocal(release) {
  const filename = path.join(RELEASES, release.filename);
  let before;
  try { before = await lstat(filename); }
  catch (error) { if (error.code === 'ENOENT') return false; throw error; }
  assert(before.isFile() && !before.isSymbolicLink(), `Refusing non-regular artifact: ${release.filename}`);
  assert(before.size === release.bytes, `Existing artifact has wrong size; left untouched: ${release.filename}`);
  const handle = await open(filename, constants.O_RDONLY | constants.O_NOFOLLOW);
  try {
    const initial = await handle.stat();
    assert(initial.isFile() && initial.size === release.bytes && initial.ino === before.ino && initial.dev === before.dev, `Artifact changed during verification: ${release.filename}`);
    const hash = createHash('sha256'); let bytes = 0;
    for await (const chunk of handle.createReadStream({ autoClose: false })) {
      bytes += chunk.length;
      assert(bytes <= release.bytes, `Existing artifact exceeds expected bytes; left untouched: ${release.filename}`);
      hash.update(chunk);
    }
    const after = await lstat(filename);
    assert(after.isFile() && !after.isSymbolicLink() && initial.ino === after.ino && initial.dev === after.dev && after.size === bytes, `Artifact changed during verification: ${release.filename}`);
    assert(bytes === release.bytes && hash.digest('hex') === release.sha256, `Existing artifact has wrong SHA-256; left untouched: ${release.filename}`);
    return true;
  } finally { await handle.close(); }
}
async function download(release, temporary) {
  const url = new URL(release.url, ORIGIN);
  assert(url.origin === ORIGIN && url.protocol === 'https:' && !url.username && !url.password && !url.search && !url.hash, 'Refusing non-public artifact URL');
  let request, response;
  const deadline = setTimeout(() => {
    const error = new Error(`Artifact download timed out: ${release.filename}`);
    response?.destroy(error); request?.destroy(error);
  }, 5 * 60_000);
  try {
    response = await new Promise((resolve, reject) => {
      request = https.get(url, { headers: { Accept: 'application/octet-stream', 'Accept-Encoding': 'identity' } }, resolve);
      request.on('error', reject);
      request.setTimeout(30_000, () => request.destroy(new Error(`Artifact download stalled: ${release.filename}`)));
    });
    // https.get never follows redirects. Reject every response except a successful, uncompressed body.
    assert(response.statusCode === 200, `Artifact server returned HTTP ${response.statusCode}; redirects are not allowed`);
    assert(!response.headers['content-encoding'] || response.headers['content-encoding'].toLowerCase() === 'identity', 'Compressed artifact response is not allowed');
    if (response.headers['content-length'] !== undefined) {
      assert(/^[0-9]+$/.test(response.headers['content-length']) && Number(response.headers['content-length']) === release.bytes, 'Artifact Content-Length differs from manifest');
    }
    let bytes = 0; const hash = createHash('sha256');
    const bounded = new Transform({
      transform(chunk, encoding, callback) {
        bytes += chunk.length;
        if (bytes > release.bytes) { callback(new Error(`Artifact download exceeds expected bytes: ${release.filename}`)); return; }
        hash.update(chunk); callback(null, chunk);
      },
    });
    await pipeline(response, bounded, createWriteStream(temporary, { flags: 'wx', mode: 0o600 }));
    assert(bytes === release.bytes && hash.digest('hex') === release.sha256, `Downloaded artifact failed size/SHA-256 verification: ${release.filename}`);
    const handle = await open(temporary, constants.O_RDWR | constants.O_NOFOLLOW);
    try { await handle.sync(); } finally { await handle.close(); }
  } finally {
    clearTimeout(deadline); response?.destroy(); request?.destroy();
  }
}
export async function prepareDownloads({ offline = false } = {}) {
  const { releases } = await manifest();
  try { await mkdir(RELEASES, { mode: 0o755 }); }
  catch (error) { if (error.code !== 'EEXIST') throw error; }
  await directory(RELEASES);
  // Validate every existing artifact first: a mismatch must fail before starting another download.
  const missing = [];
  for (const release of releases) {
    if (!await verifyLocal(release)) missing.push(release);
    else process.stdout.write(`Verified ${release.filename} (${release.bytes} bytes, SHA-256 matches)\n`);
  }
  assert(!offline || missing.length === 0, `Offline: missing artifact(s): ${missing.map(release => release.filename).join(', ')}`);
  for (const release of missing) {
    const staging = await mkdtemp(path.join(RELEASES, '.download-staging-'));
    const temporary = path.join(staging, release.filename);
    try {
      await download(release, temporary);
      await directory(RELEASES);
      // rename() can overwrite a concurrently-created destination. A same-filesystem hard link publishes atomically
      // and refuses EEXIST; removing the temporary link afterwards preserves an existing file under every outcome.
      await link(temporary, path.join(RELEASES, release.filename));
      await unlink(temporary);
      await verifyLocal(release);
      process.stdout.write(`Prepared ${release.filename} (${release.bytes} bytes, SHA-256 matches)\n`);
    } finally { await rm(staging, { recursive: true, force: true }); }
  }
  return releases.length;
}
if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const args = process.argv.slice(2);
  if (args.length > 1 || (args.length === 1 && args[0] !== '--offline')) {
    process.stderr.write('Usage: node scripts/prepare-downloads.mjs [--offline]\n'); process.exitCode = 1;
  } else {
    prepareDownloads({ offline: args[0] === '--offline' }).catch(error => { process.stderr.write(`${error.message}\n`); process.exitCode = 1; });
  }
}
