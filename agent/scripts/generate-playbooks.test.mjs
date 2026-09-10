import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, mkdir, readFile, rm, symlink, writeFile } from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { readCatalog } from '../../hub/lib/catalog.js';
import { catalogSource, generatedPath, publicCatalog } from './generate-playbooks.mjs';

const manifest = (overrides = {}) => ({
  schemaVersion: 1, id: 'fixture', name: '합성 앱', aliases: ['Fixture App'], version: '1.0.0',
  guide: 'guide.md', launch: { search: '합성 앱' }, humanSteps: ['인증은 당사자가 처리합니다.'],
  capabilities: [{ id: 'browse', title: '목록 조회', description: '공개 목록을 조회합니다.',
    inputs: [{ name: 'scope', label: '조회 범위', required: false }],
    steps: [{ id: 'open', title: '앱 열기', kind: 'open' }] }], ...overrides,
});
async function fixture(t) {
  const directory = await mkdtemp(path.join(os.tmpdir(), 'ppomi-agent-catalog-'));
  t.after(() => rm(directory, { recursive: true, force: true }));
  await writeFile(path.join(directory, 'common.md'), '# 공개 공통 절차\n');
  await mkdir(path.join(directory, 'fixture'));
  await writeFile(path.join(directory, 'fixture', 'manifest.json'), JSON.stringify(manifest()));
  await writeFile(path.join(directory, 'fixture', 'guide.md'), '# 공개 앱 절차\n');
  return directory;
}

test('generated bundle is a deterministic projection of the canonical Catalog source', async () => {
  const source = await readCatalog(catalogSource);
  const generated = JSON.parse(await readFile(generatedPath, 'utf8'));
  const expected = publicCatalog(source);
  assert.deepEqual(generated, expected);
  assert.deepEqual(generated.playbooks.map(book => book.id), source.playbooks.map(book => book.manifest.id));
  assert.ok(generated.playbooks.some(book => book.id === 'accountinfo'));
  for (const book of generated.playbooks) {
    const original = source.playbooks.find(entry => entry.manifest.id === book.id);
    assert.equal(book.guide, original.guide, 'guide text must come from the source, not a second handwritten copy');
  }
  assert.equal(generated.commonGuide, source.playbooks[0].commonGuide);
  assert.deepEqual(publicCatalog(source), expected, 'no timestamps or machine paths in generated data');
  assert.ok(!JSON.stringify(generated).includes(catalogSource));
});

test('public projection drops unknown manifest, nested metadata and asset fields', () => {
  const value = manifest({ internalCredential: 'synthetic-never-bundle', iconSource: 'https://example.invalid/public.png' });
  value.launch.privateSession = 'synthetic-never-bundle';
  value.capabilities[0].privateNotes = 'synthetic-never-bundle';
  value.capabilities[0].inputs[0].value = 'synthetic-never-bundle';
  value.capabilities[0].steps[0].recordedValue = 'synthetic-never-bundle';
  const generated = publicCatalog({ playbooks: [{ manifest: value, guide: '# Public guide', commonGuide: '# Public common',
    assets: { privatePath: 'synthetic-never-bundle' } }] });
  assert.ok(!JSON.stringify(generated).includes('synthetic-never-bundle'));
  assert.equal(generated.playbooks[0].iconSource, undefined);
  assert.equal(generated.playbooks[0].capabilities[0].inputs[0].required, false);
  const previousHash = generated.sourceSha256;
  value.capabilities[0].title = '새 공개 작업';
  assert.notEqual(publicCatalog({ playbooks: [{ manifest: value, guide: '# Public guide', commonGuide: '# Public common' }] }).sourceSha256, previousHash);
});

test('the shared Catalog validator blocks invalid manifests, path traversal and symlink guides before bundling', async t => {
  const directory = await fixture(t);
  await writeFile(path.join(directory, 'fixture', 'manifest.json'), JSON.stringify(manifest({ schemaVersion: 9 })));
  await assert.rejects(readCatalog(directory), /schemaVersion/);
  await writeFile(path.join(directory, 'fixture', 'manifest.json'), JSON.stringify(manifest({ guide: '../common.md' })));
  await assert.rejects(readCatalog(directory), /relative markdown/);
  await writeFile(path.join(directory, 'fixture', 'manifest.json'), JSON.stringify(manifest()));
  await rm(path.join(directory, 'fixture', 'guide.md'));
  await symlink(path.join(directory, 'common.md'), path.join(directory, 'fixture', 'guide.md'));
  await assert.rejects(readCatalog(directory), /symlink asset/);
  assert.throws(() => publicCatalog({ playbooks: [{ manifest: manifest({ schemaVersion: 9 }), guide: '', commonGuide: '' }] }), /schemaVersion/);
});

test('the source validator rejects colliding aliases rather than bundling an arbitrary first match', async t => {
  const directory = await fixture(t);
  await mkdir(path.join(directory, 'second'));
  await writeFile(path.join(directory, 'second', 'manifest.json'), JSON.stringify(manifest({ id: 'second', name: '두 번째 앱' })));
  await writeFile(path.join(directory, 'second', 'guide.md'), '# Second public procedure');
  await assert.rejects(readCatalog(directory), /ambiguous/);
});
