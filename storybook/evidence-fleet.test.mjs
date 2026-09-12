// evidence-fleet.js — 등급·링크·presence·서버 메타. DOM 없이 돈다: npm test
import test from 'node:test';
import assert from 'node:assert/strict';
import './evidence-fleet.js';
import {title, here, fleet, server, items, layers, pick} from './evidence-fleet-fixture.js';
const F = globalThis.EvidenceFleet;

const st = {title, here, fleet, server, items, layers};

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

test('큰 면: 서버 숫자·evidence_id, presence, 네 링크 상태, 다단. 파일 바이트 없음', () => {
  const h = F.html(st);
  assert.match(h, /class="ev-fleet"/);
  assert.match(h, /소액현금 9월/);
  assert.match(h, /164,000/);
  assert.match(h, /서버 · 파일 없음/);
  assert.match(h, /ev_tax_001/);
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
  assert.doesNotMatch(h, /\.xlsx|data:image|PK\x03\x04/);
  assert.doesNotMatch(h, /<style/);
});

test('열기는 onOpen, 오프라인 버튼은 호출 안 함', () => {
  const opened = [];
  const el = {innerHTML: '', listeners: [], addEventListener(_t, fn) { this.listeners.push(fn); }, contains() { return true; }};
  F.mount(el, {here, fleet, items: pick(['ev_tax_001', 'ev_snap_1']), onOpen: (id) => opened.push(id)});
  assert.match(el.innerHTML, /disabled>오프라인</);
  const click = (id, disabled) => el.listeners[0]({target: {closest: (q) => q === '[data-open]' ? {dataset: {open: id}, disabled} : null}});
  click('ev_tax_001', false);
  click('ev_snap_1', true);
  assert.deepEqual(opened, ['ev_tax_001']);
});

test('스냅샷 행은 적격으로 안 보이고, 빈 기기·적대 문자열은 이스케이프', () => {
  const snap = F.html({here, fleet, items: items.filter((it) => it.kind === '스냅샷'), server: {}});
  assert.match(snap, /보조 · 미연결/);
  assert.doesNotMatch(snap, /적격/);
  assert.match(F.presence([], 'mac'), /기기 없음/);
  const hostile = F.html({title: '<img src=x>', here, fleet: [{id: 'x', label: '<svg>', online: false}], items: [{evidence_id: '"><script>', kind: '스냅샷'}], server: {memo: '<b>'}});
  assert.doesNotMatch(hostile, /<img|<svg|<script|<b>/i);
  assert.match(hostile, /&lt;img src=x&gt;/);
});
