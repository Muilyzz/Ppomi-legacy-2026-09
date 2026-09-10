// evidence.js 의 논리 검사 — 태그 경로, 스키마 유도, 행 묶기·배치·겹침 제거, 마크업. 캔버스 없이 손으로 만든 화면으로 돈다: npm test
import test from 'node:test';
import assert from 'node:assert/strict';
import '../Ppomi/Sources/Ppomi/Web/evidence.js';
const E = globalThis.Evidence;

// [y, ...글자] 행 → 글자 상자. 두 번째 글자는 x 0.35 에서 시작해 0.55 에서 끝난다(오른쪽 여백).
const words = (rows) => rows.flatMap(([y, ...texts]) => texts.map((t, i) => ({text: t, x: 0.05 + i * 0.3, y, w: 0.2, h: 0.02})));
const frames = [
  {image: '', words: words([[0.10, '헤더'], [0.20, 'a', '1'], [0.30, 'b', '2'], [0.40, 'c', '3']]), top: 0, clip: 0.15, bottom: 1},
  {image: '', words: words([[0.10, '헤더'], [0.20, 'c', '3'], [0.30, 'd', '4']]), top: 0.2, clip: 0.15, bottom: 1},
];
const records = [
  {id: 'r1', tag: '비용/식비/점심/회사앞', occurredAt: '09.10', fields: {merchant: 'a', amount: -11000}, anchors: [{frame: 0, x: 0, y: 0.19, w: 1, h: 0.04}], status: 'ok'},
  {id: 'r2', tag: '비용/식비/카페', fields: {merchant: 'b', amount: -5800, balance: 100}, anchors: [{frame: 0, x: 0, y: 0.29, w: 1, h: 0.04}], status: 'warn', note: '전표 없음'},
  {id: 'r3', tag: '수익/급여', fields: {merchant: 'c', amount: 3200000}, anchors: [{frame: 0, x: 0, y: 0.39, w: 1, h: 0.04}], status: 'ok'},
  {id: 'r4', tag: '', fields: {}, anchors: [{frame: 1, x: 0, y: 0.29, w: 1, h: 0.04}], status: 'bad', note: '파싱 안 됨'},
];

test('태그 경로: 깊이로 접고, 접두어는 마디 단위로만 맞는다', () => {
  assert.equal(E.tagAt('비용/식비/점심/회사앞', 2), '비용/식비');
  assert.equal(E.tagAt('비용/식비/점심/회사앞', Infinity), '비용/식비/점심/회사앞');
  assert.equal(E.tagAt('', 3), '');
  assert.equal(E.tagDepth(records), 4);
  assert.ok(E.underTag(records[0], '비용/식비'));
  assert.ok(E.underTag(records[0], ''));
  assert.ok(!E.underTag(records[0], '비용/식'));   // '식비'의 앞글자만 같은 건 아니다
  assert.ok(!E.underTag(records[2], '비용'));
  assert.deepEqual(E.tagCounts(records, 1), [{tag: '', count: 1}, {tag: '비용', count: 2}, {tag: '수익', count: 1}]);
  assert.deepEqual(E.tagCounts(records, 2).map((c) => c.tag), ['', '비용/식비', '수익/급여']);
});

test('스키마: 없으면 필드 키의 합집합(처음 나온 순서), 있으면 그대로. 없는 값은 빈 칸', () => {
  assert.deepEqual(E.schemaOf(records).map((f) => f.key), ['merchant', 'amount', 'balance']);
  const explicit = {fields: [{key: 'amount', title: '금액', unit: '원'}]};
  assert.deepEqual(E.schemaOf(records, explicit), explicit.fields);
  assert.equal(E.cellText(-11000, explicit.fields[0]), '-11,000 원');
  assert.equal(E.cellText(72.3, {key: 'w', unit: 'kg'}), '72.3 kg');
  assert.equal(E.cellText(null, explicit.fields[0]), '');
  assert.equal(E.cellText('본죽', {key: 'm'}), '본죽');
});

test('행 묶기: y 중심이 가까운 글자는 한 행, 행 안에서는 x 순', () => {
  const rows = E.rowsOf([{text: '2', x: 0.5, y: 0.10, w: 0.1, h: 0.02}, {text: '1', x: 0.1, y: 0.105, w: 0.1, h: 0.02}, {text: '3', x: 0.1, y: 0.30, w: 0.1, h: 0.02}]);
  assert.equal(rows.length, 2);
  assert.deepEqual(rows[0].words.map((w) => w.text), ['1', '2']);
  assert.ok(Math.abs(rows[0].y0 - 0.10) < 1e-9 && Math.abs(rows[0].y1 - 0.125) < 1e-9);
});

test('배치: 크롬은 clip 으로 빼고, 두 장이 겹치는 행은 먼저 온 장의 읽기 하나만', () => {
  const placed = E.place(frames);
  assert.deepEqual(placed.map((r) => [r.frame, r.words.map((w) => w.text).join(' ')]), [[0, 'a 1'], [0, 'b 2'], [0, 'c 3'], [1, 'd 4']]);
  assert.ok(Math.abs(placed[3].y - 0.5) < 1e-9);
  const ext = E.extent(frames);
  assert.ok(Math.abs(ext.base - 0.15) < 1e-9 && Math.abs(ext.height - 1.05) < 1e-9);
  assert.deepEqual(E.extent([]), {base: 0, height: 0});
  assert.equal(E.rightMargin(placed), 0.55);
});

test('마크업: 글자는 제자리에, 기록은 근거 상자로, 표는 스키마 열로. CSS 는 없다', () => {
  const st = {frames, records, depth: 2, tag: '', selected: 'r2', schema: {fields: [{key: 'merchant', title: '가맹점'}, {key: 'amount', title: '금액', unit: '원'}]}};
  const h = E.html(st);
  assert.equal((h.match(/class="ev-word"/g) || []).length, 8);
  assert.equal((h.match(/class="ev-box/g) || []).length, 4 + 2);   // 근거 4 + 범례 2
  assert.match(h, /class="ev-box warn hit" data-record="r2"/);
  assert.match(h, /<tr data-record="r2" aria-selected="true">/);
  assert.match(h, /<th scope="col">가맹점<\/th><th scope="col">금액<\/th><th scope="col">상태<\/th>/);
  assert.match(h, /<td class="n">-11,000 원<\/td>/);
  assert.match(h, /<td><small class="meta">미분류<\/small><\/td>/);
  assert.match(h, /data-tag="비용\/식비" aria-pressed="false">비용\/식비 2</);
  assert.match(h, /기록 4건 · 화면 2장/);
  assert.match(h, /전표 없음/); assert.match(h, /파싱 안 됨/);
  assert.equal((h.match(/data-depth=/g) || []).length, 4);
  assert.doesNotMatch(h, /<style/);
  const filtered = E.html({...st, tag: '수익'});
  assert.equal((filtered.match(/<tr data-record=/g) || []).length, 1);
  assert.match(E.html({...st, tag: '없음'}), /이 태그에 기록이 없습니다/);
  assert.match(E.html({frames: [], records: []}), /기록 0건 · 화면 0장/);
});
