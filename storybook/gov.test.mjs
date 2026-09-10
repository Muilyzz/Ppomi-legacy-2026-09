// gov-fixture.js — docs/gov-sites.md 파서. 트리 338줄이 기록 338건, 표·출처 절은 건너뛴다.
import test from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import {parseGovSites, govSchema} from './gov-fixture.js';
const md = readFileSync(new URL('../docs/gov-sites.md', import.meta.url), 'utf8');

test('공공사이트 트리 → 기록: 분야/부처/기관 경로, 링크·패키지 분리, 뒤의 표는 무시', () => {
  const r = parseGovSites(md);
  assert.equal(r.length, 338);
  assert.deepEqual(r[0].fields, {site: '복권위원회', url: 'http://www.bokgwon.go.kr/', path: '재정·세금/재정경제부/재정경제부 본부·복권위원회', task: '복권 정책·기금 안내 열람', login: '없음', target: 'Mac', priority: 'P5', pkg: '', count: 1});
  const home = r.find((x) => x.fields.site === '홈택스');
  assert.equal(home.fields.pkg, 'hometax'); assert.equal(home.fields.priority, 'P1'); assert.equal(home.fields.path, '재정·세금/국세청/국세청 본청');
  assert.ok(r.every((x) => x.fields.path.split('/').length === 3 && x.fields.url.startsWith('http')));
  assert.ok(r.some((x) => x.fields.target === 'Windows'));
  assert.equal(r.filter((x) => x.fields.priority <= 'P2').length, r.filter((x) => x.fields.priority === 'P1' || x.fields.priority === 'P2').length);
  assert.ok(govSchema.fields.find((f) => f.type === 'path') && govSchema.fields.find((f) => f.type === 'amount'));
});
