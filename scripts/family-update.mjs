#!/usr/bin/env node
// Family web releases: reviewed repository assets only, signed offline, no publishing or app installation.
import { createHash, createPrivateKey, createPublicKey, generateKeyPairSync, sign, verify } from 'node:crypto';
import { lstat, mkdir, readFile, readdir, realpath, writeFile } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

export const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
export const LIMITS = Object.freeze({ files: 512, fileBytes: 8 * 1024 * 1024, totalBytes: 16 * 1024 * 1024, envelopeBytes: 32 * 1024 * 1024 });
export const CAPABILITIES = Object.freeze({ macos: ['agent.v1', 'records.v1'], ipados: ['records.v1'], android: ['agent.v1'] });
export const REQUIRED = Object.freeze({
  macos: ['Agent/index.html', 'Agent/app.js', 'Agent/app.css', 'playbooks.json', 'timeline.html', 'evidence.html', 'tokens.css', 'theme.css',
    'simple.css', 'evidence.js', 'playbook.js', 'facts.js', 'journal.js', 'schedule.js', 'verify.js'],
  android: ['Agent/index.html', 'Agent/app.js', 'Agent/app.css', 'playbooks.json'],
  ipados: ['pad.html', 'pad.js', 'pad.css', 'timeline.html', 'tokens.css', 'theme.css', 'journal.html', 'journal.js'],
});
const extensions = new Set(['html', 'js', 'css', 'json', 'woff2', 'png', 'jpg', 'jpeg', 'svg', 'webp']);
const digest = (bytes) => createHash('sha256').update(bytes).digest('hex');
function requireThat(condition, message) { if (!condition) throw new Error(message); }
function exactKeys(value, keys, label) {
  requireThat(value && typeof value === 'object' && !Array.isArray(value), `${label}: expected object`);
  requireThat(Object.keys(value).sort().join(',') === [...keys].sort().join(','), `${label}: unexpected or missing fields`);
}
function positiveInteger(value) { return Number.isInteger(value) && value > 0 && value <= 2147483647; }
export function decodeBase64(value, label) {
  // A repeated quartet regex can exhaust the JS regexp stack on a valid multi-MiB asset.
  requireThat(typeof value === 'string' && value.length % 4 === 0 && !/[^A-Za-z0-9+/=]/.test(value), `${label}: invalid base64`);
  const bytes = Buffer.from(value, 'base64');
  requireThat(bytes.toString('base64') === value, `${label}: noncanonical base64`);
  return bytes;
}
export function validatePath(value) {
  requireThat(typeof value === 'string' && value.length <= 240 && value.split('/').every(segment => /^[A-Za-z0-9_-][A-Za-z0-9._-]*$/.test(segment)), 'unsafe file path');
  requireThat(extensions.has(value.split('.').at(-1).toLowerCase()), `unsupported file extension: ${value}`);
}
export function validatePayload(payload, expected = {}) {
  exactKeys(payload, ['formatVersion', 'release', 'sequence', 'channel', 'platform', 'bridgeVersion', 'minNativeBuild', 'capabilities', 'files'], 'payload');
  requireThat(payload.formatVersion === 1 && payload.bridgeVersion === 1 && payload.minNativeBuild === 1, 'unsupported format, bridge or native build');
  requireThat(typeof payload.release === 'string' && /^[a-z0-9][a-z0-9._-]{0,63}$/.test(payload.release), 'invalid release');
  requireThat(positiveInteger(payload.sequence), 'invalid sequence');
  requireThat(['preview', 'family'].includes(payload.channel) && Object.hasOwn(CAPABILITIES, payload.platform), 'invalid channel or platform');
  for (const field of ['platform', 'channel']) if (expected[field]) requireThat(payload[field] === expected[field], `${field} mismatch`);
  if (expected.afterSequence !== undefined) requireThat(payload.sequence > expected.afterSequence, 'replayed sequence');
  requireThat(Array.isArray(payload.capabilities) && payload.capabilities.length === CAPABILITIES[payload.platform].length &&
    [...payload.capabilities].sort().join(',') === [...CAPABILITIES[payload.platform]].sort().join(','), 'invalid capabilities');
  requireThat(Array.isArray(payload.files) && payload.files.length > 0 && payload.files.length <= LIMITS.files, 'invalid file count');
  const names = new Set(); let total = 0;
  for (const file of payload.files) {
    exactKeys(file, ['path', 'sha256', 'data'], 'file'); validatePath(file.path);
    const normalized = file.path.toLowerCase();
    requireThat(!names.has(normalized), 'duplicate file path'); names.add(normalized);
    requireThat(typeof file.sha256 === 'string' && /^[a-f0-9]{64}$/.test(file.sha256), 'invalid sha256');
    requireThat(typeof file.data === 'string' && file.data.length <= Math.ceil(LIMITS.fileBytes / 3) * 4, 'file too large');
    const bytes = decodeBase64(file.data, file.path); total += bytes.length;
    requireThat(bytes.length <= LIMITS.fileBytes && total <= LIMITS.totalBytes, 'decoded files too large');
    requireThat(digest(bytes) === file.sha256, `hash mismatch: ${file.path}`);
  }
  for (const name of names) {
    const parts = name.split('/'); parts.pop();
    while (parts.length) { requireThat(!names.has(parts.join('/')), 'file/directory path collision'); parts.pop(); }
  }
  for (const required of REQUIRED[payload.platform]) requireThat(payload.files.some(file => file.path === required), `missing required file: ${required}`);
  return payload;
}
function publicKeyFromRaw(raw) {
  const bytes = decodeBase64(raw, 'public key');
  requireThat(bytes.length === 65 && bytes[0] === 4, 'public key must be an uncompressed P-256 point');
  return createPublicKey({ key: { kty: 'EC', crv: 'P-256', x: bytes.subarray(1, 33).toString('base64url'), y: bytes.subarray(33).toString('base64url') }, format: 'jwk' });
}
export function rawPublicKey(key) {
  const jwk = createPublicKey(key).export({ format: 'jwk' });
  requireThat(jwk.kty === 'EC' && jwk.crv === 'P-256', 'signing key must be P-256');
  return Buffer.concat([Buffer.from([4]), Buffer.from(jwk.x, 'base64url'), Buffer.from(jwk.y, 'base64url')]).toString('base64');
}
export function encodePackage(payload, privateKey) {
  validatePayload(payload); rawPublicKey(privateKey);
  const bytes = Buffer.from(JSON.stringify(payload));
  const envelope = Buffer.from(JSON.stringify({ payload: bytes.toString('base64'), signature: sign('sha256', bytes, { key: privateKey, dsaEncoding: 'der' }).toString('base64') }));
  requireThat(envelope.length <= LIMITS.envelopeBytes, 'envelope too large');
  return envelope;
}
export function verifyPackage(envelope, publicKey, expected = {}) {
  requireThat(Buffer.byteLength(envelope) <= LIMITS.envelopeBytes, 'envelope too large');
  const wrapper = JSON.parse(new TextDecoder('utf-8', { fatal: true }).decode(Buffer.from(envelope)));
  exactKeys(wrapper, ['payload', 'signature'], 'envelope');
  const bytes = decodeBase64(wrapper.payload, 'payload'), signature = decodeBase64(wrapper.signature, 'signature');
  requireThat(verify('sha256', bytes, { key: publicKeyFromRaw(publicKey), dsaEncoding: 'der' }, signature), 'invalid signature');
  return validatePayload(JSON.parse(new TextDecoder('utf-8', { fatal: true }).decode(bytes)), expected);
}
export function validateConfig(config) {
  exactKeys(config, ['formatVersion', 'endpoint', 'publicKey', 'channel'], 'config');
  requireThat(config.formatVersion === 1 && ['preview', 'family'].includes(config.channel), 'invalid config version or channel');
  const url = new URL(config.endpoint);
  requireThat(url.protocol === 'https:' && !url.username && !url.password && !url.search && !url.hash, 'endpoint must be HTTPS without credentials, query or fragment');
  requireThat(new RegExp(`/${config.channel}/(macos|ipados|android)\\.json$`).test(url.pathname), 'endpoint must end with channel/platform.json');
  publicKeyFromRaw(config.publicKey); return config;
}
async function collect(directory, prefix = '') {
  const files = [];
  for (const entry of (await readdir(directory, { withFileTypes: true })).sort((a, b) => a.name.localeCompare(b.name, 'en'))) {
    const location = path.join(directory, entry.name), name = prefix + entry.name;
    requireThat(!entry.isSymbolicLink(), `symbolic links are not release assets: ${name}`);
    if (entry.isDirectory()) files.push(...await collect(location, name + '/'));
    else if (entry.isFile() && extensions.has(entry.name.split('.').at(-1).toLowerCase())) {
      validatePath(name);
      requireThat((await lstat(location)).size <= LIMITS.fileBytes, `file too large: ${name}`);
      files.push([name, await readFile(location)]);
    }
  }
  return files;
}
export async function repositoryFiles(platform, root = ROOT) {
  requireThat(Object.hasOwn(CAPABILITIES, platform), 'invalid platform');
  const web = path.join(root, 'Ppomi/Sources/Ppomi/Web');
  // Refuse a checkout with only placeholder/stale entry files. The production build carries the readiness handshake.
  const entry = await readFile(path.join(web, 'Agent/index.html'), 'utf8');
  const script = await readFile(path.join(web, 'Agent/app.js'), 'utf8');
  const css = await readFile(path.join(web, 'Agent/app.css'), 'utf8');
  requireThat(entry.includes('./app.js') && entry.includes('./app.css') && entry.includes('Content-Security-Policy') && script.includes('updateReady') && css.length > 100, 'build agent first: generated Agent assets or updateReady handshake missing');
  const files = new Map(await collect(web));
  const playbooks = await readFile(path.join(root, 'agent/src/generated/playbooks.json'));
  const catalog = JSON.parse(playbooks);
  requireThat(catalog.schemaVersion === 1 && Array.isArray(catalog.playbooks), 'invalid generated public playbook catalog');
  files.set('playbooks.json', playbooks);
  if (platform === 'ipados') for (const [name, bytes] of await collect(path.join(root, 'iPad/Web'))) files.set(name, bytes);
  return [...files].sort(([a], [b]) => a.localeCompare(b, 'en')).map(([name, bytes]) => ({ path: name, sha256: digest(bytes), data: bytes.toString('base64') }));
}
function flags(args) {
  const values = {};
  for (let i = 0; i < args.length; i += 2) {
    requireThat(/^--[a-z-]+$/.test(args[i]) && args[i + 1] && !args[i + 1].startsWith('--'), 'flags require values');
    const key = args[i].slice(2); requireThat(!Object.hasOwn(values, key), `duplicate flag: ${key}`); values[key] = args[i + 1];
  }
  return values;
}
function requireFlags(values, required, optional = []) {
  requireThat(required.every(key => values[key]) && Object.keys(values).every(key => [...required, ...optional].includes(key)), `expected flags: ${required.map(key => '--' + key).join(' ')}`);
}
async function safeKeyPath(value) {
  requireThat(path.isAbsolute(value), 'key path must be absolute and outside the repository');
  const parent = await realpath(path.dirname(value));
  const repository = await realpath(ROOT), resolved = path.join(parent, path.basename(value));
  requireThat(resolved !== repository && !resolved.startsWith(repository + path.sep), 'private keys must stay outside the repository');
  return resolved;
}
export async function main(args) {
  const [command, ...rest] = args, options = flags(rest);
  if (command === 'keygen') {
    requireFlags(options, ['key']); const keyPath = await safeKeyPath(options.key);
    const { privateKey } = generateKeyPairSync('ec', { namedCurve: 'prime256v1' });
    await writeFile(keyPath, privateKey.export({ format: 'pem', type: 'pkcs8' }), { flag: 'wx', mode: 0o600 });
    const publicKey = rawPublicKey(privateKey);
    await writeFile(keyPath + '.public-key.txt', publicKey + '\n', { flag: 'wx', mode: 0o644 });
    process.stdout.write(`Created offline signing key: ${keyPath}\nPublic key: ${keyPath}.public-key.txt\n`);
  } else if (command === 'pack') {
    requireFlags(options, ['platform', 'channel', 'release', 'sequence', 'key', 'out']);
    const keyPath = await safeKeyPath(options.key);
    requireThat(!(await lstat(keyPath)).isSymbolicLink(), 'private key must not be a symbolic link');
    const payload = { formatVersion: 1, release: options.release, sequence: Number(options.sequence), channel: options.channel, platform: options.platform,
      bridgeVersion: 1, minNativeBuild: 1, capabilities: CAPABILITIES[options.platform], files: await repositoryFiles(options.platform) };
    const envelope = encodePackage(payload, createPrivateKey(await readFile(keyPath)));
    await mkdir(path.dirname(path.resolve(options.out)), { recursive: true });
    await writeFile(options.out, envelope, { flag: 'wx' });
    process.stdout.write(`Signed ${payload.platform}/${payload.channel} ${payload.release} sequence ${payload.sequence}: ${options.out} (${envelope.length} bytes)\n`);
  } else if (command === 'validate-config') {
    requireFlags(options, ['config']);
    const config = validateConfig(JSON.parse(await readFile(options.config, 'utf8')));
    process.stdout.write(`Validated update config for ${config.channel}\n`);
  } else if (command === 'verify') {
    requireFlags(options, ['package', 'public-key'], ['platform', 'channel', 'after-sequence']);
    const payload = verifyPackage(await readFile(options.package), (await readFile(options['public-key'], 'utf8')).trim(), {
      platform: options.platform, channel: options.channel, afterSequence: options['after-sequence'] === undefined ? undefined : Number(options['after-sequence']),
    });
    process.stdout.write(`Verified ${payload.platform}/${payload.channel} ${payload.release} sequence ${payload.sequence}: ${payload.files.length} files\n`);
  } else throw new Error('Usage: family-update.mjs keygen --key /outside/repo/signing.pem | pack --platform macos|ipados|android --channel preview|family --release NAME --sequence N --key /outside/repo/signing.pem --out FILE | verify --package FILE --public-key FILE [--platform NAME --channel NAME --after-sequence N] | validate-config --config FILE');
}
if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) main(process.argv.slice(2)).catch(error => { process.stderr.write(`${error.message}\n`); process.exitCode = 1; });
