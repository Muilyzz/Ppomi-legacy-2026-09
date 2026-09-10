import { readFile, readdir, lstat } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

export const defaultCatalogRoot = process.env.VERCEL
  ? path.join(process.cwd(), 'catalog')
  : fileURLToPath(new URL('../catalog/', import.meta.url));
const stableID = /^[a-z][a-z0-9-]{0,63}$/;
const version = /^[0-9]+\.[0-9]+\.[0-9]+(?:-[0-9A-Za-z.-]+)?(?:\+[0-9A-Za-z.-]+)?$/;
const kinds = new Set(['open', 'human', 'tap', 'read', 'scroll', 'close', 'payment', 'choice', 'input', 'coupon', 'payment-method']);
const imageExtension = /\.(?:png|jpe?g|gif|webp|icns|tiff?)$/i;
const object = value => value !== null && typeof value === 'object' && !Array.isArray(value);
const nonempty = value => typeof value === 'string' && value.trim().length > 0;
const validName = value => nonempty(value) && [...value].length <= 120 && value !== '.' && value !== '..' && !/[\/\\\p{Cc}\p{Cf}]/u.test(value);
const normalize = value => value.trim().normalize('NFC').toLowerCase();
// JavaScript's $ also matches before a final newline. Require the actual entire string.
const fullMatch = (value, expression) => typeof value === 'string' && value.match(expression)?.[0] === value;

function requireValue(condition, reason) {
  if (!condition) throw new Error(`Invalid catalog: ${reason}`);
}

/** Package files are relative data paths; URLs, traversal and symlinks are never followed. */
export function isSafeAssetPath(value) {
  return nonempty(value) && !/[\\:\p{Cc}\p{Cf}]/u.test(value) &&
    value.split('/').every(part => part.length > 0 && part !== '.' && part !== '..');
}

export function validateManifest(manifest, directoryID = manifest?.id) {
  requireValue(object(manifest), 'manifest object');
  requireValue(manifest.schemaVersion === 1, 'schemaVersion must be 1');
  requireValue(fullMatch(manifest.id, stableID) && manifest.id === directoryID, 'id must match its package directory');
  requireValue(validName(manifest.name), 'name');
  requireValue(fullMatch(manifest.version, version), 'semantic version');
  requireValue(Array.isArray(manifest.aliases) && manifest.aliases.every(validName), 'aliases');
  requireValue(isSafeAssetPath(manifest.guide) && /\.md$/i.test(manifest.guide), 'guide must be a relative markdown path');
  if (manifest.icon !== undefined && manifest.icon !== null) {
    requireValue(isSafeAssetPath(manifest.icon) && imageExtension.test(manifest.icon), 'icon must be a relative image path');
  }
  if (manifest.iconSource !== undefined && manifest.iconSource !== null) {
    requireValue(typeof manifest.iconSource === 'string', 'iconSource must be a web URL string');
    let url;
    try { url = new URL(manifest.iconSource); } catch { /* validation below */ }
    requireValue(['http:', 'https:'].includes(url?.protocol) && url.hostname, 'iconSource must be a web URL');
  }
  requireValue(object(manifest.launch) && nonempty(manifest.launch.search), 'launch.search');
  const target = manifest.launch.target;
  requireValue(target == null || target === 'browser' || target === 'windows', 'launch.target must be browser, windows or omitted');
  if (target != null) {
    const value = manifest.launch.search;
    let url;
    try { url = new URL(value); } catch { /* validation below */ }
    requireValue(!/[\s\\\p{Cc}]/u.test(value) && /^https?:\/\//i.test(value) &&
      ['http:', 'https:'].includes(url?.protocol) && url.hostname &&
      !url.username && !url.password && !value.slice(value.indexOf('://') + 3).split(/[/?#]/, 1)[0].includes('@'),
    `${target} launch.search must be an HTTP(S) URL without credentials`);
    requireValue(manifest.collection == null, `${target} packages cannot use phone collection`);
  }
  requireValue(Array.isArray(manifest.humanSteps) && manifest.humanSteps.every(nonempty), 'humanSteps');
  requireValue(Array.isArray(manifest.capabilities) && manifest.capabilities.length > 0, 'capabilities');
  const capabilityIDs = new Set();
  for (const capability of manifest.capabilities) {
    requireValue(object(capability) && fullMatch(capability.id, stableID) && !capabilityIDs.has(capability.id), 'unique capability id');
    capabilityIDs.add(capability.id);
    requireValue(nonempty(capability.title) && nonempty(capability.description), 'capability title and description');
    requireValue(Array.isArray(capability.inputs), 'capability inputs');
    const inputNames = new Set();
    for (const input of capability.inputs) {
      requireValue(object(input) && fullMatch(input.name, /^[a-z][a-zA-Z0-9_-]{0,63}$/) && nonempty(input.label) && typeof input.required === 'boolean' && !inputNames.has(input.name), 'unique named input with label and required flag');
      inputNames.add(input.name);
    }
    requireValue(Array.isArray(capability.steps) && capability.steps.length > 0, 'capability steps');
    const stepIDs = new Set();
    for (const step of capability.steps) {
      requireValue(object(step) && fullMatch(step.id, stableID) && !stepIDs.has(step.id) && nonempty(step.title) && kinds.has(step.kind), 'unique step id, title and supported kind');
      stepIDs.add(step.id);
    }
  }
  if (manifest.collection !== undefined && manifest.collection !== null) {
    const collection = manifest.collection;
    requireValue(object(collection) && fullMatch(collection.key, /^[A-Z][A-Z0-9_]{0,63}$/) && nonempty(collection.account), 'collection key and account');
    requireValue([manifest.id, manifest.name, ...manifest.aliases].some(name => normalize(name) === normalize(collection.key)), 'collection key must identify its app');
    for (const key of ['homeLabel', 'expand', 'list', 'tx', 'txpage', 'home']) {
      if (collection[key] !== undefined && collection[key] !== null) requireValue(typeof collection[key] === 'string', `collection ${key}`);
    }
    if (collection.scrollY !== undefined && collection.scrollY !== null) requireValue(Number.isFinite(collection.scrollY) && collection.scrollY >= 0 && collection.scrollY <= 1, 'collection scrollY');
  }
  return manifest;
}

/** Check each component so a safe-looking nested path cannot escape through a symlink. */
export async function readPackageFile(root, relativePath) {
  requireValue(isSafeAssetPath(relativePath), 'unsafe asset path');
  let current = root;
  const components = relativePath.split('/');
  for (let index = 0; index < components.length; index++) {
    current = path.join(current, components[index]);
    const stat = await lstat(current);
    requireValue(!stat.isSymbolicLink(), 'symlink asset');
    requireValue(index === components.length - 1 ? stat.isFile() : stat.isDirectory(), 'asset file type');
  }
  return readFile(current);
}

const publicAsset = (id, asset) => `/catalog/${[id, ...asset.split('/')].map(encodeURIComponent).join('/')}`;

/** Discover data packages, with no app-specific list or inferred claims of verification. */
export async function readCatalog(root = defaultCatalogRoot) {
  const rootStat = await lstat(root);
  requireValue(rootStat.isDirectory() && !rootStat.isSymbolicLink(), 'catalog directory');
  const commonGuide = (await readPackageFile(root, 'common.md')).toString('utf8');
  const playbooks = [];
  const names = new Map();
  const entries = (await readdir(root, { withFileTypes: true })).sort((a, b) => a.name.localeCompare(b.name));
  for (const entry of entries) {
    if (entry.name.startsWith('.')) continue;
    requireValue(!entry.isSymbolicLink(), 'symlink package');
    if (!entry.isDirectory()) continue;
    const packageRoot = path.join(root, entry.name);
    const manifest = validateManifest(JSON.parse((await readPackageFile(packageRoot, 'manifest.json')).toString('utf8')), entry.name);
    const guide = (await readPackageFile(packageRoot, manifest.guide)).toString('utf8');
    if (manifest.icon) await readPackageFile(packageRoot, manifest.icon);
    for (const name of [manifest.id, manifest.name, ...manifest.aliases]) {
      const key = normalize(name);
      requireValue(!names.has(key) || names.get(key) === manifest.id, 'ambiguous id, name or alias');
      names.set(key, manifest.id);
    }
    playbooks.push({
      manifest,
      guide,
      commonGuide,
      assets: {
        manifest: publicAsset(manifest.id, 'manifest.json'),
        guide: publicAsset(manifest.id, manifest.guide),
        ...(manifest.icon ? { icon: publicAsset(manifest.id, manifest.icon) } : {}),
        commonGuide: '/catalog/common.md',
      },
    });
  }
  return { schemaVersion: 1, playbooks };
}

export function findPlaybook(catalog, query) {
  if (!nonempty(query)) return undefined;
  const key = normalize(query);
  return catalog.playbooks.find(({ manifest }) => [manifest.id, manifest.name, ...manifest.aliases].some(name => normalize(name) === key));
}
