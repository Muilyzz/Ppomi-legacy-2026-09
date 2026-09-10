// verify.js — 단계별 최신 판정 요약(버전 묶음·마지막 판정 우선·stale), 기능별 기록 파생, playbook.js 의 판정 표시. 명세는 Catalog 원본, 판정은 가짜(playbook-fixture.js).
import test from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import '../Ppomi/Sources/Ppomi/Web/playbook.js';
import '../Ppomi/Sources/Ppomi/Web/verify.js';
import {yeogiWalk, fakeLedger} from './playbook-fixture.js';
const V = globalThis.Verify, P = globalThis.Playbook;
const manifest = (id) => JSON.parse(readFileSync(new URL(`../Ppomi/Sources/Ppomi/Catalog/${id}/manifest.json`, import.meta.url), 'utf8'));

test('요약: 현재 버전의 단계별 마지막 판정, 다른 버전은 stale, 미검증 = 나머지', () => {
  const s = V.summary(manifest('yeogi'), fakeLedger.yeogi);
  assert.deepEqual([s.total, s.ok, s.changed, s.fail, s.unverified, s.stale], [10, 5, 1, 0, 4, 0]);   // step-8 은 fail 뒤 ok
  assert.equal(s.steps['prepare-booking/step-6'].actual, '필수 동의 항목 전체 선택');
  const h = V.summary(manifest('hometax'), fakeLedger.hometax);
  assert.deepEqual([h.total, h.ok, h.unverified, h.stale], [28, 0, 28, 3]);
  assert.deepEqual(V.summary(manifest('gov24'), []).steps, {});
});

test('기록 파생: 기능마다 하나, 경로는 대상/패키지/기능, 미검증이 첫 amount 라 트리맵 크기가 된다', () => {
  const {records, schema} = V.records([{manifest: manifest('yeogi'), footprints: yeogiWalk, ledger: fakeLedger.yeogi}, {manifest: manifest('hometax'), footprints: [], ledger: fakeLedger.hometax}, {manifest: manifest('gov24'), footprints: [], ledger: []}]);
  assert.equal(records.length, 1 + 3 + 3);
  assert.deepEqual(records[0], {id: 'yeogi/prepare-booking', fields: {cap: '숙소 탐색 · 객실 비교 · 예약 준비', path: '폰/여기어때/숙소 탐색 · 객실 비교 · 예약 준비', unverified: 4, total: 10, ok: 5, changed: 1, fail: 0, walks: 12, last: '2026-09-10', pkg: 'yeogi'}});
  assert.ok(records.slice(1, 4).every((r) => r.fields.path.startsWith('Mac 브라우저/홈택스/') && r.fields.last === null));
  assert.ok(records.slice(4).every((r) => r.fields.path.startsWith('Windows/정부24/') && r.fields.unverified === r.fields.total));
  assert.equal(schema.fields.find((f) => f.type === 'amount').key, 'unverified');
});

test('절차 뷰의 판정: ✓△✗ 표시와 클래스, 판정이 있으면 발자국 휴리스틱보다 앞선다, 헤더에 미검증 수', () => {
  const m = manifest('yeogi'), v = V.summary(m, fakeLedger.yeogi), h = P.html({manifest: m, footprints: yeogiWalk, verification: v});
  assert.ok(h.includes('class="pb-step ok"') && h.includes('class="pb-step changed"') && h.includes('△ ↓⊙ 필수') && h.includes('실제: 필수 동의 항목 전체 선택'));
  assert.ok(!h.includes('✗ ') && h.includes('판정 ✓5 △1 ✗0 · 미검증 4'));
  const t = P.tree(m.capabilities);
  assert.equal(P.verdict(t.nodes[7], v).outcome, 'ok');   // step-8: fail 뒤 ok
  assert.equal(P.verdict(t.nodes[9], v), null);          // step-10: 판정 없음 → 발자국으로 '걸어 봄'
  assert.ok(h.includes('· ⊙ 결제하기'));
});
