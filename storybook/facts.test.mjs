// facts.js 의 논리 검사 — 값 종류 표기, 트리맵 집계·배치, 시간축 항목·눈금, 평면도 투영, 디스패처의 뷰 선택. DOM 없이 돈다: npm test
import test from 'node:test';
import assert from 'node:assert/strict';
import '../Ppomi/Sources/Ppomi/Web/facts.js';
import {building, loan, car, spending, holdings} from './facts-fixture.js';
const X = globalThis.Facts;

test('값 종류 → 글자·칸: 단위, 퍼센트, 미입력, 출처 등급, 다각형', () => {
  assert.equal(X.fmt(1234, {type: 'amount', unit: '㎡'}), '1,234 ㎡');
  assert.equal(X.fmt(3500, {type: 'ratio'}), '35%');
  assert.equal(X.fmt(Date.UTC(2026, 8, 10), {type: 'time'}), '2026-09-10');
  assert.equal(X.fmt({points: [1, 2, 3]}, {type: 'place'}), '다각형 3점');
  assert.equal(X.fmt({lat: 37.5, lng: 127}, {type: 'place'}), '37.50000, 127.00000');
  assert.equal(X.fmt('estimated', {type: 'provenance'}), '추정');
  assert.match(X.cell(3500, {type: 'ratio'}), /<meter min="0" max="10000" value="3500"><\/meter> 35%/);
  assert.match(X.cell(null, {type: 'ratio'}), /미입력/);
  assert.match(X.cell('ocr', {type: 'provenance'}), /class="prov prov-ocr">화면에서 읽음/);
  assert.equal(X.cell(120, {type: 'amount', unit: '㎡'}), '<td class="n">120 ㎡</td>');
});

test('트리맵 집계: 깊이로 접고, 뿌리 아래만, 더 깊은 마디가 있으면 deeper', () => {
  const top = X.nodes(building.records, 'floor', 'area', '', 1);
  assert.deepEqual(top, [{path: '건물', label: '건물', value: 1120, deeper: true}]);
  const floors = X.nodes(building.records, 'floor', 'area', '', 2);
  assert.equal(floors.length, 6);
  assert.deepEqual(floors.slice(0, 2).map((n) => [n.path, n.value, n.deeper]), [['건물/지하1층', 320, false], ['건물/1층', 320, false]]);
  assert.ok(floors.find((n) => n.path === '건물/2층').deeper);
  assert.deepEqual(X.nodes(building.records, 'floor', 'area', '건물/2층', 1).map((n) => [n.label, n.value]), [['201호', 60], ['202호', 60]]);
  assert.equal(X.nodes([{id: 'x', fields: {p: 'a', v: -5}}], 'p', 'v', '', 1)[0].value, 5);   // 크기는 절대값
});

test('트리맵 배치: 넓이는 값에 비례, 상자는 겹치지 않고 밖으로 나가지 않는다', () => {
  const items = [{value: 50}, {value: 30}, {value: 12}, {value: 5}, {value: 3}];
  const boxes = X.layout(items, 0, 0, 640, 260, []);
  assert.equal(boxes.length, 5);
  const area = boxes.reduce((s, b) => s + b.w * b.h, 0);
  assert.ok(Math.abs(area - 640 * 260) < 1e-6);
  boxes.forEach((b) => { assert.ok(Math.abs(b.w * b.h / (640 * 260) - b.item.value / 100) < 1e-9); assert.ok(b.x >= 0 && b.y >= 0 && b.x + b.w <= 640 + 1e-9 && b.y + b.h <= 260 + 1e-9); });
  for (let i = 0; i < boxes.length; i++) for (let j = i + 1; j < boxes.length; j++) {
    const a = boxes[i], b = boxes[j];
    assert.ok(a.x + a.w <= b.x + 1e-9 || b.x + b.w <= a.x + 1e-9 || a.y + a.h <= b.y + 1e-9 || b.y + b.h <= a.y + 1e-9, `overlap ${i} ${j}`);
  }
  assert.deepEqual(X.layout([], 0, 0, 10, 10, []), []);
});

test('시간축 항목: until 이 있으면 막대, 끝 필드는 점이 되지 않는다, 시작순', () => {
  const sp = X.spans(loan.records, loan.schema.fields);
  assert.equal(sp.length, 13);
  assert.equal(sp[0].record, 'loan'); assert.equal(sp[0].end - sp[0].start, Date.UTC(2029, 2, 15) - Date.UTC(2024, 2, 15));
  assert.ok(sp.slice(1).every((s) => s.end == null));
  for (let i = 1; i < sp.length; i++) assert.ok(sp[i - 1].start <= sp[i].start);
  const carSp = X.spans(car.records, car.schema.fields);
  assert.deepEqual(carSp.map((s) => s.label), ['자동차등록증 · 최초등록일', '자동차보험 · 보험 시작', '엔진오일 교환 · 정비일', '타이어 교체 · 정비일']);
  assert.equal(carSp[1].prov, 'manual');
});

test('눈금: 12개 이하, 오름차순, 범위에 맞는 단위', () => {
  const days = X.ticks(Date.UTC(2026, 8, 1), Date.UTC(2026, 8, 11));
  assert.ok(days.length >= 10 && days.length <= 12); assert.equal(days[0].label, '9/1');
  const months = X.ticks(Date.UTC(2026, 0, 10), Date.UTC(2026, 9, 10));
  assert.ok(months.length <= 12 && months.length >= 9); assert.equal(months[0].label, '2026-02');
  const years = X.ticks(Date.UTC(2005, 0, 1), Date.UTC(2026, 0, 1));
  assert.equal(years.length, 22); assert.equal(years[0].label, '2005');
  [days, months, years].forEach((ts) => { for (let i = 1; i < ts.length; i++) assert.ok(ts[i].t > ts[i - 1].t); });
});

test('평면도 투영: 위도 1° ≈ 110.6 km, 경도는 cos(위도) 만큼 줄고, {x,y} 는 미터 그대로', () => {
  const [a, b] = X.project([{pts: [{lat: 37.5, lng: 127}]}, {pts: [{lat: 38.5, lng: 128}]}]);
  assert.deepEqual(a.xy, [[0, 0]]);
  assert.ok(Math.abs(b.xy[0][1] - 110574) < 1);
  assert.ok(Math.abs(b.xy[0][0] - 111320 * Math.cos(37.5 * Math.PI / 180)) < 1);
  const shapes = X.shapesOf(building.records, building.schema.fields);
  assert.equal(shapes.length, 2); assert.ok(shapes[0].polygon); assert.deepEqual(shapes[0].xy[1], [24, 0]);
  assert.equal(X.shapesOf(spending.records, spending.schema.fields).length, 8);
});

test('디스패처: 스키마의 값 종류만 보고 뷰를 붙인다. CSS 는 없다', () => {
  const b = X.html({...building, depth: 2});
  assert.match(b, /class="fx-table"/); assert.match(b, /class="fx-timeline"/); assert.match(b, /class="fx-treemap"/); assert.match(b, /class="fx-places"/);
  assert.match(b, /<polygon points="/); assert.match(b, /<meter /); assert.match(b, /class="prov prov-estimated">추정/);
  assert.equal((b.match(/data-path=/g) || []).length, 6);
  assert.match(b, /data-depth="2" class="on"/);
  assert.doesNotMatch(b, /<style/);
  const c = X.html({...car});
  assert.match(c, /fx-timeline/); assert.doesNotMatch(c, /fx-treemap/); assert.doesNotMatch(c, /fx-places/);
  assert.match(c, /<code>12가3456<\/code>/);
  const h = X.html({...holdings, depth: 3, selected: 'h4'});
  assert.match(h, /aria-selected="true"/); assert.match(h, /fx-treemap/); assert.doesNotMatch(h, /fx-places/);
  const drilled = X.html({...building, root: '건물/2층', depth: 1});
  assert.match(drilled, /data-root="건물" [^>]*>← 건물\/2층/); assert.equal((drilled.match(/data-path=/g) || []).length, 2);
  assert.match(X.html({records: [], schema: {fields: []}}), /기록이 없습니다/);
});
