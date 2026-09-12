// evidence-fleet.js — 등급·링크·presence·서버 메타. DOM 없이 돈다: npm test
import test from 'node:test';
import assert from 'node:assert/strict';
import './evidence-fleet.js';
import {title, here, fleet, server, items, layers, pick} from './evidence-fleet-fixture.js';
const F = globalThis.EvidenceFleet;

const st = {title, here, fleet, server, items, layers};
const visible = (h) => h.replace(/<[^>]+>/g, ' ');

test('적격은 공식 4종만, 스냅샷·StepResult·그 외는 보조. 넘겨준 grade는 무시', () => {
  assert.deepEqual(F.OFFICIAL, ['세금계산서', '카드', '현금영수증', '계산서']);
  F.OFFICIAL.forEach((k) => assert.equal(F.gradeOf(k), '적격'));
  assert.equal(F.gradeOf('스냅샷'), '보조');
  assert.equal(F.gradeOf('StepResult'), '보조');
  assert.equal(F.gradeOf('영수증'), '보조');
});

test('링크: 로컬 즉시, 피어 온라인이면 E2E, 오프면 비활성, 암호문 캐시면 그 안내', () => {
  assert.equal(F.linkState({host: 'mac'}, fleet, 'mac'), 'open');
  assert.equal(F.linkState({host: 'local'}, fleet, 'mac'), 'open');
  assert.equal(F.linkState({}, fleet, 'mac'), 'open');
  assert.equal(F.linkState({host: 'win'}, fleet, 'mac'), 'e2e');
  assert.equal(F.linkState({host: 'phone'}, fleet, 'mac'), 'disabled');
  assert.equal(F.linkState({host: 'phone', cache: 'ciphertext'}, fleet, 'mac'), 'cache');
  assert.equal(F.linkLabel('open'), '열기');
  assert.equal(F.linkLabel('e2e'), 'E2E');
});

test('링크 라벨은 기기 · 종류, 보조만 (보조). 시각은 있으면 붙고 키는 ms', () => {
  assert.equal(F.itemLabel({kind: '세금계산서', host: 'mac'}, st), 'Mac · 세금계산서');
  assert.equal(F.itemLabel({kind: '카드', host: 'win'}, st), 'Win · 카드');
  assert.equal(F.itemLabel({kind: '스냅샷', host: 'phone'}, st), 'Phone · 스냅샷(보조)');
  assert.equal(F.itemLabel(items[0], st), 'Mac · 세금계산서 · 9.12 01:10');
  assert.equal(F.itemLabel(items[4], st), 'Phone · 스냅샷(보조) · 9.12 00:05');
  assert.equal(F.hostLabel(fleet, 'mac'), 'Mac');
  assert.equal(F.timeFull(items[0].collectedAtMs), '2026-09-12 01:10:00.123');
  assert.equal(F.timeFull(items[2].collectedAtMs), '2026-09-12 01:10:00.789');
  assert.ok(items.every((it) => Number.isInteger(it.collectedAtMs)));
  assert.ok(items.some((it) => it.collectedAtMs % 1000 !== 0));
});

test('큰 면: 서버 숫자, presence, 네 링크 상태, 다단. id·파일 바이트 없음', () => {
  const h = F.html(st);
  assert.match(h, /class="ev-fleet"/);
  assert.match(h, /소액현금 9월/);
  assert.match(h, /164,000/);
  assert.match(h, /서버 · 파일 없음 · 증빙 6건/);
  assert.match(h, /Mac · 세금계산서 · 9.12 01:10/);
  assert.match(h, /Win · 카드 · 9.11 08:22/);
  assert.match(h, /Phone · 스냅샷\(보조\) · 9.12 00:05/);
  assert.match(h, new RegExp('data-host="mac" data-collected="' + items[0].collectedAtMs + '"'));
  assert.match(h, /2026-09-12 01:10:00.123/);
  assert.match(h, /2026-09-12 01:10:00.789/);
  assert.match(h, /data-device="mac" data-online="true"/);
  assert.match(h, /data-device="phone" data-online="false"/);
  assert.match(h, /이 기기 · 온라인/);
  assert.match(h, /피어 · 오프라인/);
  assert.match(h, /data-link="open"/);
  assert.match(h, /data-link="e2e"/);
  assert.match(h, /data-link="disabled"/);
  assert.match(h, /data-link="cache"/);
  assert.match(h, /disabled>/);
  assert.match(h, /암호문만 · 원문 없음/);
  assert.match(h, /적격 · 연결/);
  assert.match(h, /보조 · 미연결/);
  assert.match(h, /1 폰 훑어보기/);
  assert.match(h, /3 공식 첨부/);
  assert.match(h, /popover/);
  assert.match(h, /미리보기 · 파일은 기기 · 바이트 없음/);
  assert.doesNotMatch(visible(h), /ev_tax_001|ev_card_002|ev_cash_003|ev_bill_004|ev_snap_1|ev_step_1/);
  assert.doesNotMatch(h, /<code>ev_/);
  assert.doesNotMatch(h, /\.xlsx|data:image|PK\x03\x04/);
  assert.doesNotMatch(h, /<style/);
});

test('디버그면 id가 서버·표·다단에 보인다', () => {
  const h = F.html({...st, debug: true});
  assert.match(h, /<code>ev_tax_001<\/code>/);
  assert.match(h, /<th>evidence_id<\/th>/);
});

test('열기는 onOpen, 오프라인 버튼은 호출 안 함', () => {
  const opened = [];
  const el = {innerHTML: '', listeners: [], addEventListener(_t, fn) { this.listeners.push(fn); }, contains() { return true; }};
  F.mount(el, {here, fleet, items: pick(['ev_tax_001', 'ev_snap_1']), onOpen: (id) => opened.push(id)});
  assert.match(el.innerHTML, /disabled>Phone · 스냅샷\(보조\) · 9.12 00:05</);
  const click = (id, disabled) => el.listeners[0]({target: {closest: (q) => q === '[data-open]' ? {dataset: {open: id}, disabled} : null}});
  click('ev_tax_001', false);
  click('ev_snap_1', true);
  assert.deepEqual(opened, ['ev_tax_001']);
});

test('스냅샷 행은 적격으로 안 보이고, 빈 기기·적대 문자열은 이스케이프', () => {
  const snap = F.html({here, fleet, items: items.filter((it) => it.kind === '스냅샷'), server: {}});
  assert.match(snap, /보조 · 미연결/);
  assert.match(snap, /Phone · 스냅샷\(보조\) · 9.12 00:05/);
  assert.doesNotMatch(snap, /적격/);
  assert.match(F.presence([], 'mac'), /기기 없음/);
  const hostile = F.html({title: '<img src=x>', here, fleet: [{id: 'x', label: '<svg>', online: false}], items: [{evidence_id: '"><script>', kind: '스냅샷'}], server: {memo: '<b>'}});
  assert.doesNotMatch(hostile, /<img|<svg|<script|<b>/i);
  assert.match(hostile, /&lt;img src=x&gt;/);
});
