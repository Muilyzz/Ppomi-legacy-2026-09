// schedule.js 의 논리 검사 — 기대일 생성, 배정은 한 번씩, 납부·부분납·미납·예정 판정, 연체 막대. npm test
import test from 'node:test';
import assert from 'node:assert/strict';
import '../Ppomi/Sources/Ppomi/Web/schedule.js';
import {rules, rentEntries, TODAY} from './lease-fixture.js';
const S = globalThis.Schedule;
const ymd = (ms) => new Date(ms).toISOString().slice(0, 10);

test('기대일: 매월 N일, from~to 안, 없는 날은 말일', () => {
  assert.deepEqual(S.dues({day: 31, from: '2026-01-31', to: '2026-04-30'}).map(ymd), ['2026-01-31', '2026-02-28', '2026-03-31', '2026-04-30']);
  assert.deepEqual(S.dues({day: 5, from: '2025-11-10', to: '2026-01-10'}).map(ymd), ['2025-12-05', '2026-01-05']);   // 첫 달은 이미 지난 5일 제외
  assert.deepEqual(S.dues({day: 1, from: '2026-03-01', to: '2026-02-01'}), []);
});

test('판정: 같은 달 안의 분개만, 한 번씩만 배정. 납부·부분납·미납·예정', () => {
  const rule = [{id: 'r', path: 'a/b', day: 10, amount: 100, from: '2026-01-01', to: '2026-05-31', label: 'x'}];
  const entries = [{at: '2026-01-12', path: 'a/b', amount: 100}, {at: '2026-02-03', path: 'a/b', amount: 40}, {at: '2026-02-20', path: 'a/b/c', amount: 60}, {at: '2026-03-15', path: 'a/z', amount: 100}, {at: '2026-04-10', path: 'a/b', amount: 100}, {at: '2026-04-11', path: 'a/b', amount: 100}];
  const out = S.reconcile(rule, entries, '2026-04-20');
  assert.deepEqual(out.map((r) => [r.fields.due, r.fields.status, r.fields.actual, r.fields.settled]), [
    ['2026-01-10', 'paid', 100, '2026-01-12'],      // 이틀 늦게 → 막대 2일
    ['2026-02-10', 'paid', 100, '2026-02-20'],      // 40 + 하위 경로 60
    ['2026-03-10', 'unpaid', 0, '2026-04-20'],      // 다른 경로 a/z 는 안 침 → 오늘까지 막대
    ['2026-04-10', 'paid', 100, '2026-04-10'],      // 두 번째 100 은 남는다(중복 배정 없음)
    ['2026-05-10', 'upcoming', 0, null],
  ]);
  assert.equal(out[0].fields.state, '납부'); assert.equal(out[2].fields.state, '미납'); assert.equal(out[4].fields.state, '예정');
  assert.equal(S.SCHEMA.fields.find((f) => f.key === 'due').until, 'settled');
  assert.ok(out.every((r) => r.fields.prov === 'derived'));   // 판정은 계산이지 관측이 아니다
  assert.equal(S.SCHEMA.fields.find((f) => f.type === 'provenance').key, 'prov');
});

test('임대 픽스처: 201호 7월 미납·8월 연체, 202호 6월 부분납·9월 예정, 301호 전부 납부', () => {
  const out = S.reconcile(rules, rentEntries, TODAY), by = (id) => out.find((r) => r.id === id).fields;
  assert.equal(by('c-201:2026-07-05').status, 'unpaid'); assert.equal(by('c-201:2026-07-05').settled, TODAY);
  assert.equal(by('c-201:2026-08-05').status, 'paid'); assert.equal(by('c-201:2026-08-05').settled, '2026-08-21');
  assert.equal(by('c-201:2025-11-05').settled, '2025-11-07');
  assert.equal(by('c-202:2026-06-15').status, 'partial'); assert.equal(by('c-202:2026-06-15').actual, 400000);
  assert.equal(by('c-202:2026-09-15').status, 'upcoming');
  assert.ok(out.filter((r) => r.id.startsWith('c-301')).every((r) => r.fields.status === 'paid'));
  assert.equal(out.filter((r) => r.id.startsWith('c-301')).length, 24);
  assert.equal(rentEntries.length, 24 + 18 + 8);
});
