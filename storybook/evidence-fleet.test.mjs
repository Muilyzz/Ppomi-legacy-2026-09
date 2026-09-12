// evidence/ — Panel + Presence/Links/Grid/Preview/ServerMeta. DOM 없이 돈다: npm test
import test from 'node:test';
import assert from 'node:assert/strict';
import './evidence-fleet.js';
import {title, here, fleet, server, items, layers, pick} from './evidence-fleet-fixture.js';
const Evidence = globalThis.Evidence;

const st = {title, here, fleet, server, items, layers};
const visible = (h) => h.replace(/<[^>]+>/g, ' ');

test('공개 API는 Panel과 자식. 단일 mount는 없다', () => {
  assert.equal(typeof Evidence.Panel.mount, 'function');
  assert.equal(typeof Evidence.Panel.html, 'function');
  ['Presence', 'Links', 'Grid', 'Preview', 'ServerMeta'].forEach((name) => {
    assert.equal(typeof Evidence[name].html, 'function');
    assert.equal(typeof Evidence[name].mount, 'function');
    assert.equal(globalThis[name], undefined);
  });
  // 잠금 면은 Panel.mount. Evidence.mount 가 있으면 OCR 스티치(증거)다.
  if (Evidence.mount) assert.equal(typeof Evidence.tagAt, 'function');
  else assert.equal(Evidence.html, undefined);
  assert.equal(globalThis.EvidenceFleet, undefined);
});

test('Panel은 자식 HTML을 조립만 한다', () => {
  const p = Evidence.Panel.html(st);
  assert.match(p, /data-ev="panel"/);
  assert.ok(p.includes(Evidence.Presence.html(st)));
  assert.ok(p.includes(Evidence.Links.html(st)));
  assert.ok(p.includes(Evidence.Grid.html(st)));
  assert.ok(p.includes(Evidence.ServerMeta.html(st)));
  assert.match(p, /<div class="sec">서버<\/div>/);
  assert.match(p, /<div class="sec">기기<\/div>/);
  assert.match(p, /<div class="sec">그리드<\/div>/);
  assert.match(p, /<div class="sec">링크<\/div>/);
});

test('적격은 공식 4종만, 스냅샷·StepResult·그 외는 보조. 넘겨준 grade는 무시', () => {
  assert.deepEqual(Evidence.OFFICIAL, ['세금계산서', '카드', '현금영수증', '계산서']);
  Evidence.OFFICIAL.forEach((k) => assert.equal(Evidence.gradeOf(k), '적격'));
  assert.equal(Evidence.gradeOf('스냅샷'), '보조');
  assert.equal(Evidence.gradeOf('StepResult'), '보조');
  assert.equal(Evidence.gradeOf('영수증'), '보조');
});

test('링크: 로컬 즉시, 피어 온라인이면 E2E, 오프면 비활성, 암호문 캐시면 그 안내', () => {
  assert.equal(Evidence.linkState({host: 'mac'}, fleet, 'mac'), 'open');
  assert.equal(Evidence.linkState({host: 'local'}, fleet, 'mac'), 'open');
  assert.equal(Evidence.linkState({}, fleet, 'mac'), 'open');
  assert.equal(Evidence.linkState({host: 'win'}, fleet, 'mac'), 'e2e');
  assert.equal(Evidence.linkState({host: 'phone'}, fleet, 'mac'), 'disabled');
  assert.equal(Evidence.linkState({host: 'phone', cache: 'ciphertext'}, fleet, 'mac'), 'cache');
  assert.equal(Evidence.linkLabel('open'), '열기');
  assert.equal(Evidence.linkLabel('e2e'), 'E2E');
});

test('링크 라벨은 기기 · 종류, 보조만 (보조). 시각은 있으면 붙고 키는 ms', () => {
  assert.equal(Evidence.itemLabel({kind: '세금계산서', host: 'mac'}, st), 'Mac · 세금계산서');
  assert.equal(Evidence.itemLabel({kind: '카드', host: 'win'}, st), 'Win · 카드');
  assert.equal(Evidence.itemLabel({kind: '스냅샷', host: 'phone'}, st), 'Phone · 스냅샷(보조)');
  assert.equal(Evidence.itemLabel(items[0], st), 'Mac · 세금계산서 · 9.12 01:10');
  assert.equal(Evidence.itemLabel(items[4], st), 'Phone · 스냅샷(보조) · 9.12 00:05');
  assert.equal(Evidence.hostLabel(fleet, 'mac'), 'Mac');
  assert.equal(Evidence.timeFull(items[0].collectedAtMs), '2026-09-12 01:10:00.123');
  assert.equal(Evidence.timeFull(items[2].collectedAtMs), '2026-09-12 01:10:00.789');
  assert.ok(items.every((it) => Number.isInteger(it.collectedAtMs)));
  assert.ok(items.some((it) => it.collectedAtMs % 1000 !== 0));
});

test('큰 면: 서버 숫자, presence, 네 링크 상태, 다단. id·파일 바이트 없음', () => {
  const h = Evidence.Panel.html(st);
  assert.match(h, /class="ev-fleet"/);
  assert.match(h, /소액현금 9월/);
  assert.match(h, /164,000/);
  assert.match(h, /서버 · 파일 없음 · 증빙 7건/);
  assert.match(h, /미부착/);
  assert.match(h, /미리보기 없음 · 기기 미부착/);
  assert.doesNotMatch(h, /<img|data:image/);
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
  assert.match(h, /class="ev-hover"/);
  assert.match(h, /role="tooltip"/);
  assert.match(h, /미리보기 · 파일은 기기 · 바이트 없음/);
  assert.match(h, /미리보기 · E2E · 바이트 없음/);
  assert.match(h, /암호문 캐시 · 오프라인 · 원문 없음/);
  assert.match(h, /오프라인 · 미리보기 불가/);
  assert.doesNotMatch(h, /popover|popovertarget/);
  assert.doesNotMatch(visible(h), /ev_tax_001|ev_card_002|ev_cash_003|ev_bill_004|ev_snap_1|ev_step_1|ev_gone_1/);
  assert.doesNotMatch(h, /<code>ev_/);
  assert.doesNotMatch(h, /\.xlsx|data:image|PK\x03\x04/);
  assert.doesNotMatch(h, /<style/);
});

test('미리보기 종류: 로컬·E2E·수신·세션·암호문·오프·미부착. 원문 바이트 없음', () => {
  const tax = items[0], card = items[1], snap = items[4], step = items[5];
  assert.equal(Evidence.previewKind(tax, st), 'local');
  assert.equal(Evidence.previewKind(card, st), 'e2e');
  assert.equal(Evidence.previewKind(card, {...st, inflight: {ev_card_002: true}}), 'receive');
  assert.equal(Evidence.previewKind(card, {...st, session: {ev_card_002: true}}), 'session');
  assert.equal(Evidence.previewKind(step, st), 'ciphertext');
  assert.equal(Evidence.previewKind(snap, st), 'offline');
  assert.equal(Evidence.previewKind(null, st), 'empty');
  assert.equal(Evidence.Preview.kind(tax, st), 'local');
  const shown = Evidence.Panel.html({...st, hover: 'ev_tax_001', items: pick(['ev_tax_001']), layers: []});
  assert.match(shown, /data-show="1"/);
  assert.match(shown, /data-preview="local"/);
  const spin = Evidence.Panel.html({...st, hover: 'ev_card_002', inflight: {ev_card_002: true}, items: pick(['ev_card_002']), layers: []});
  assert.match(spin, /ev-spin/);
  assert.match(spin, /aria-busy="true"/);
  assert.match(spin, /수신 중/);
  const sess = Evidence.Panel.html({...st, hover: 'ev_card_002', session: {ev_card_002: true}, items: pick(['ev_card_002']), layers: []});
  assert.match(sess, /세션 미리보기 · 바이트 없음/);
  assert.doesNotMatch(sess, /ev-spin|수신 중/);
  assert.doesNotMatch(spin + sess, /<img|data:image|\.xlsx|PK\x03\x04/);
});

test('디버그면 id가 서버·표·다단에 보인다', () => {
  const h = Evidence.Panel.html({...st, debug: true});
  assert.match(h, /<code>ev_tax_001<\/code>/);
  assert.match(h, /<th>evidence_id<\/th>/);
});

test('열기는 onOpen, 오프라인 버튼은 호출 안 함. 클릭은 미리보기 안 연다', () => {
  const opened = [];
  const el = {innerHTML: '', listeners: [], addEventListener(_t, fn) { this.listeners.push(fn); }, contains() { return true; }};
  Evidence.Panel.mount(el, {here, fleet, items: pick(['ev_tax_001', 'ev_snap_1']), onOpen: (id) => opened.push(id)});
  assert.match(el.innerHTML, /disabled>Phone · 스냅샷\(보조\) · 9.12 00:05</);
  assert.doesNotMatch(el.innerHTML, /data-show/);
  const click = (id, disabled) => el.listeners[0]({target: {closest: (q) => q === '[data-open]' ? {dataset: {open: id}, disabled} : null}});
  click('ev_tax_001', false);
  click('ev_snap_1', true);
  assert.deepEqual(opened, ['ev_tax_001']);
  assert.equal(el.listeners.length, 2);
});

test('E2E hover 1회는 스피너 후 세션 캐시. re-hover는 다시 안 받는다', async () => {
  const el = {innerHTML: '', listeners: [], addEventListener(_t, fn) { this.listeners.push(fn); }, contains() { return true; }};
  const ui = Evidence.Panel.mount(el, {here, fleet, items: pick(['ev_card_002']), receiveMs: 0});
  const hover = (id) => el.listeners[1]({target: {closest: (q) => q === '[data-hover]' ? {dataset: {hover: id}} : null}});
  hover('ev_card_002');
  assert.match(el.innerHTML, /수신 중/);
  assert.equal(ui.state().inflight.ev_card_002, true);
  await new Promise((r) => setTimeout(r, 0));
  assert.match(el.innerHTML, /세션 미리보기 · 바이트 없음/);
  assert.equal(ui.state().session.ev_card_002, true);
  assert.equal(ui.state().inflight.ev_card_002, undefined);
  el.innerHTML = 'keep';
  hover('ev_card_002');
  assert.equal(el.innerHTML, 'keep');
});

test('썸네일: 열리면 채움, 오프·미부착·암호문만이면 빈 칸', () => {
  assert.equal(Evidence.thumbFilled({host: 'mac'}, fleet, 'mac'), true);
  assert.equal(Evidence.thumbFilled({host: 'win'}, fleet, 'mac'), true);
  assert.equal(Evidence.thumbFilled({host: 'phone'}, fleet, 'mac'), false);
  assert.equal(Evidence.thumbFilled({host: 'phone', cache: 'ciphertext'}, fleet, 'mac'), false);
  assert.equal(Evidence.thumbFilled({host: 'ghost'}, fleet, 'mac'), false);
  assert.deepEqual(Evidence.timesOf(items), items.map((it) => it.collectedAtMs).slice().sort((a, b) => a - b));
  assert.deepEqual(Evidence.hostsOf(st), ['mac', 'win', 'phone']);
});

test('그리드: 기기 행 × 시각 열, 온라인 채움·오프 빈 칸. hover 미리보기, id·가짜 이미지 없음', () => {
  const g = Evidence.Grid.html(st);
  assert.match(g, /data-ev="grid"/);
  assert.match(g, /aria-label="기기 × 시각"/);
  assert.match(g, /data-device="mac"/);
  assert.match(g, /data-device="win"/);
  assert.match(g, /data-device="phone"/);
  items.forEach((it) => assert.match(g, new RegExp('data-collected="' + it.collectedAtMs + '"')));
  assert.match(g, /data-fill="1" data-link="open"/);
  assert.match(g, /data-fill="1" data-link="e2e"/);
  assert.match(g, /data-fill="0" data-link="disabled"/);
  assert.match(g, /data-fill="0" data-link="cache"/);
  assert.match(g, /Mac · 세금계산서 · 9.12 01:10/);
  assert.match(g, /Phone · 스냅샷\(보조\) · 9.12 00:05/);
  assert.match(g, /class="ev-hover"/);
  assert.match(g, /role="tooltip"/);
  assert.doesNotMatch(g, /popover|popovertarget/);
  assert.doesNotMatch(visible(g), /ev_tax_001|ev_card_002|ev_cash_003|ev_bill_004|ev_snap_1|ev_step_1/);
  assert.doesNotMatch(g, /data:image|<img|PK\x03\x04|\.xlsx/);
  assert.match(Evidence.Grid.html({here, fleet, items: []}), /그리드 없음/);
});

test('자식 mount도 같은 클릭·hover 규칙을 쓴다', () => {
  const opened = [];
  const el = {innerHTML: '', listeners: [], addEventListener(_t, fn) { this.listeners.push(fn); }, contains() { return true; }};
  Evidence.Links.mount(el, {here, fleet, items: pick(['ev_tax_001', 'ev_snap_1']), onOpen: (id) => opened.push(id)});
  assert.match(el.innerHTML, /data-ev="links"/);
  const click = (id, disabled) => el.listeners[0]({target: {closest: (q) => q === '[data-open]' ? {dataset: {open: id}, disabled} : null}});
  click('ev_tax_001', false);
  click('ev_snap_1', true);
  assert.deepEqual(opened, ['ev_tax_001']);
});

test('스냅샷 행은 적격으로 안 보이고, 빈 기기·적대 문자열은 이스케이프', () => {
  const snap = Evidence.Panel.html({here, fleet, items: items.filter((it) => it.kind === '스냅샷'), server: {}});
  assert.match(snap, /보조 · 미연결/);
  assert.match(snap, /Phone · 스냅샷\(보조\) · 9.12 00:05/);
  assert.doesNotMatch(snap, /적격/);
  assert.match(Evidence.Presence.html({fleet: [], here: 'mac'}), /기기 없음/);
  const hostile = Evidence.Panel.html({title: '<img src=x>', here, fleet: [{id: 'x', label: '<svg>', online: false}], items: [{evidence_id: '"><script>', kind: '스냅샷'}], server: {memo: '<b>'}});
  assert.doesNotMatch(hostile, /<img|<svg|<script|<b>/i);
  assert.match(hostile, /&lt;img src=x&gt;/);
});
