import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, mkdir, writeFile, readFile, readdir, rm, symlink } from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { createCatalogHandler } from '../api/playbooks.js';
import { readCatalog, validateManifest } from '../lib/catalog.js';
import { syncCatalog } from '../../scripts/sync-catalog.mjs';
import { call } from './fx.js';

function manifest(overrides = {}) {
  return {
    schemaVersion: 1,
    id: 'sample-app',
    name: '새로운 앱',
    version: '1.0.0',
    aliases: ['Sample App'],
    icon: 'images/official.png',
    iconSource: 'https://example.com/official-app',
    launch: { search: '새로운 앱' },
    capabilities: [{
      id: 'browse', title: '목록 탐색', description: '공개 목록을 탐색합니다.',
      inputs: [{ name: 'query', label: '검색어', required: false }],
      steps: [{ id: 'open', title: '앱 열기', kind: 'open' }, { id: 'browse-list', title: '목록 읽기', kind: 'read' }],
    }],
    humanSteps: ['로그인과 인증은 직접 합니다.'],
    guide: 'guide.md',
    ...overrides,
  };
}

async function fixture(t) {
  const directory = await mkdtemp(path.join(os.tmpdir(), 'ppomi-catalog-'));
  t.after(() => rm(directory, { recursive: true, force: true }));
  const source = path.join(directory, 'source');
  await mkdir(source);
  await writeFile(path.join(source, 'common.md'), '# 공통\n결제는 사람이 승인합니다.\n');
  return { directory, source };
}

async function writePackage(source, value = manifest()) {
  const directory = path.join(source, value.id);
  await mkdir(path.join(directory, 'images'), { recursive: true });
  await writeFile(path.join(directory, 'manifest.json'), JSON.stringify(value, null, 2) + '\n');
  await writeFile(path.join(directory, 'guide.md'), '# 새로운 앱\n절차는 데이터에서 읽습니다.\n');
  await writeFile(path.join(directory, 'images/official.png'), Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]));
  return directory;
}

test('a new package becomes discoverable without an app-specific code list or restart', async t => {
  const { source } = await fixture(t);
  const handler = createCatalogHandler(source);
  assert.deepEqual((await call(handler)).body.playbooks, []);
  const expected = manifest();
  await writePackage(source, expected);
  const result = await call(handler);
  assert.equal(result.code, 200);
  assert.equal(result.body.schemaVersion, 1);
  assert.equal(result.body.playbooks.length, 1);
  const record = result.body.playbooks[0];
  assert.deepEqual(record.manifest, expected, 'the hub serves the canonical manifest without reinterpretation');
  assert.match(record.guide, /절차는 데이터/);
  assert.match(record.commonGuide, /사람이 승인/);
  assert.deepEqual(record.assets, {
    manifest: '/catalog/sample-app/manifest.json',
    guide: '/catalog/sample-app/guide.md',
    icon: '/catalog/sample-app/images/official.png',
    commonGuide: '/catalog/common.md',
  });
  assert.equal(record.verified, undefined, 'declared capabilities are not advertised as local execution evidence');
});

test('stable id, display name and aliases resolve to the same catalog record', async t => {
  const { source } = await fixture(t);
  await writePackage(source);
  const handler = createCatalogHandler(source);
  for (const id of ['sample-app', '새로운 앱', '  SAMPLE APP  ']) {
    const result = await call(handler, { query: { id } });
    assert.equal(result.code, 200);
    assert.equal(result.body.manifest.id, 'sample-app');
  }
  assert.equal((await call(handler, { query: { id: '../sample-app/manifest.json' } })).code, 404);
  assert.equal((await call(handler, { query: { id: ['sample-app'] } })).code, 400);
  const post = await call(handler, { method: 'POST', body: manifest() });
  assert.equal(post.code, 405);
  assert.equal(post.headers.Allow, 'GET');
});

test('unsupported schemas, invalid versions and unsafe asset paths are rejected', async t => {
  const { source } = await fixture(t);
  const invalid = [
    { schemaVersion: 2 }, { schemaVersion: '1' }, { version: 'latest' },
    { guide: '../secret.md' }, { guide: '/tmp/secret.md' }, { guide: 'folder//guide.md' },
    { guide: 'folder/./guide.md' }, { guide: 'folder\\guide.md' },
    { icon: 'https://example.com/image.png' }, { icon: '../outside.png' },
  ];
  for (const override of invalid) {
    await writePackage(source, manifest(override));
    await assert.rejects(readCatalog(source), /Invalid catalog:/, JSON.stringify(override));
  }
  const result = await call(createCatalogHandler(source));
  assert.equal(result.code, 503);
  assert.deepEqual(result.body, { reasons: ['catalog unavailable'] }, 'API errors do not expose filesystem paths');
});

test('symlink assets cannot include files from outside the package', async t => {
  const { directory, source } = await fixture(t);
  const packageDirectory = await writePackage(source);
  const external = path.join(directory, 'private.md');
  await writeFile(external, 'private information');
  await rm(path.join(packageDirectory, 'guide.md'));
  await symlink(external, path.join(packageDirectory, 'guide.md'));
  await assert.rejects(readCatalog(source), /symlink asset/);
});

test('ambiguous aliases and directory identity mismatches fail validation', async t => {
  const { source } = await fixture(t);
  await writePackage(source);
  const otherDirectory = await writePackage(source, manifest({ id: 'other-app', name: '다른 앱' }));
  await assert.rejects(readCatalog(source), /ambiguous/);
  await writeFile(path.join(otherDirectory, 'manifest.json'), JSON.stringify(manifest({ id: 'changed-app', name: '다른 앱', aliases: [] })));
  await assert.rejects(readCatalog(source), /id must match/);
});

test('staging copies only canonical manifest, guide, icon and common guide bytes', async t => {
  const { directory, source } = await fixture(t);
  const packageDirectory = await writePackage(source);
  await writeFile(path.join(packageDirectory, 'local.jsonl'), 'private execution evidence');
  await writeFile(path.join(packageDirectory, '.env'), 'private credentials');
  const target = path.join(directory, 'staged');
  await mkdir(path.join(target, 'old-app'), { recursive: true });
  await writeFile(path.join(target, 'old-app/stale.json'), '{}');
  assert.equal(await syncCatalog(source, target), 1);
  assert.deepEqual((await readdir(target)).sort(), ['common.md', 'sample-app']);
  assert.deepEqual((await readdir(path.join(target, 'sample-app'))).sort(), ['guide.md', 'images', 'manifest.json']);
  for (const file of ['common.md', 'sample-app/manifest.json', 'sample-app/guide.md', 'sample-app/images/official.png']) {
    assert.deepEqual(await readFile(path.join(target, file)), await readFile(path.join(source, file)), file);
  }
  const record = (await call(createCatalogHandler(target), { query: { id: 'sample-app' } })).body;
  assert.equal(record.manifest.version, '1.0.0');
});

test('a bad source leaves the last valid generated catalog intact', async t => {
  const { directory, source } = await fixture(t);
  await writePackage(source);
  const target = path.join(directory, 'staged');
  await syncCatalog(source, target);
  await writePackage(source, manifest({ schemaVersion: 99 }));
  await assert.rejects(syncCatalog(source, target), /schemaVersion/);
  assert.equal((await readCatalog(target)).playbooks[0].manifest.schemaVersion, 1);
  await assert.rejects(syncCatalog(source, source), /separate directories/);
});

test('optional web sources remain strings and a null scroll position uses the app default', () => {
  assert.throws(() => validateManifest(manifest({ iconSource: ['https://example.com/official-app'] })), /iconSource/);
  for (const scrollY of [undefined, null, 0, 0.5, 1]) {
    const value = manifest({ aliases: ['SAMPLE_APP'], collection: { key: 'SAMPLE_APP', account: '계좌|통장', scrollY } });
    assert.equal(validateManifest(value), value, 'validation preserves the canonical representation');
  }
  for (const scrollY of ['0.5', false, -1, 2]) {
    assert.throws(() => validateManifest(manifest({ aliases: ['SAMPLE_APP'], collection: { key: 'SAMPLE_APP', account: '계좌|통장', scrollY } })), /scrollY/);
  }
});

test('identifiers and versions must match in full, including rejection of a trailing newline', () => {
  const badValues = [manifest({ id: 'sample-app\n' }), manifest({ version: '1.0.0\n' })];
  const capability = manifest();
  capability.capabilities[0].id += '\n';
  badValues.push(capability);
  const step = manifest();
  step.capabilities[0].steps[0].id += '\n';
  badValues.push(step);
  const input = manifest();
  input.capabilities[0].inputs[0].name += '\n';
  badValues.push(input);
  badValues.push(manifest({ aliases: ['SAMPLE_APP'], collection: { key: 'SAMPLE_APP\n', account: '계좌' } }));
  for (const value of badValues) assert.throws(() => validateManifest(value), /Invalid catalog:/);
});

test('browser launch metadata preserves legacy packages and validates native navigation URLs', async t => {
  const { source } = await fixture(t);
  for (const launch of [{ search: 'sample' }, { search: 'https://example.com/', target: null },
    { search: 'https://example.com/path?q=public#section', target: 'browser' }]) {
    const value = manifest({ launch });
    assert.equal(validateManifest(value), value);
  }
  const value = manifest({ launch: { search: 'https://example.com/', target: 'browser' } });
  await writePackage(source, value);
  assert.deepEqual((await call(createCatalogHandler(source))).body.playbooks[0].manifest.launch, value.launch);
  for (const search of ['sample', 'file:///tmp/a', 'javascript:alert(1)', 'https://',
    'https://user:secret@example.com/', 'https://@example.com/', 'https://example.com/\n',
    'https://example.com/a b', 'https:example.com', 'https:\\example.com']) {
    assert.throws(() => validateManifest(manifest({ launch: { search, target: 'browser' } })), /browser launch.search/);
  }
  assert.throws(() => validateManifest(manifest({ launch: { search: 'sample', target: 'shell' } })), /launch.target/);
  const windows = manifest({ launch: { search: 'https://example.com/exe', target: 'windows' } });
  assert.equal(validateManifest(windows), windows);
  assert.throws(() => validateManifest(manifest({ launch: { search: 'https://user:secret@example.com/', target: 'windows' } })), /windows launch.search/);
  assert.throws(() => validateManifest(manifest({ ...windows, collection: { key: 'SAMPLE_APP', account: '계좌' } })), /phone collection/);
  assert.throws(() => validateManifest(manifest({ ...value, collection: { key: 'SAMPLE_APP', account: '계좌' } })), /phone collection/);
});
