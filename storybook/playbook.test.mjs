// playbook.js 의 논리 검사 — 명세 접기, 화면 뭉치기, 사이클 층, 걸어 본 단계, html. 명세는 Catalog 원본, 발자국은 가짜(playbook-fixture.js). DOM 없이 돈다: npm test
import test from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import '../Ppomi/Sources/Ppomi/Web/playbook.js';
import {yeogiWalk} from './playbook-fixture.js';
const P = globalThis.Playbook;
const manifest = (id) => JSON.parse(readFileSync(new URL(`../Ppomi/Sources/Ppomi/Catalog/${id}/manifest.json`, import.meta.url), 'utf8'));

test('명세 나무: 홈택스 기능 셋(28단계)의 앞 4단계가 한 줄기로 접혀 19노드, 잎 셋, 깊이 10', () => {
  const t = P.tree(manifest('hometax').capabilities);
  assert.equal(t.nodes.length, 19); assert.equal(t.cols, 3); assert.equal(t.depth, 10);
  assert.deepEqual(t.nodes.slice(0, 4).map((n) => n.caps.length), [3, 3, 3, 3]);
  assert.equal(t.nodes.filter((n) => n.depth === 4).length, 2);   // 장려금·연말정산 | 계산서·영수증·카드 에서 갈라진다
  assert.ok(t.nodes.every((n) => n.depth === 0 ? !n.parent : n.parent.depth === n.depth - 1));
  assert.equal(P.glyphOf({title: '기업 인증서 정보 입력', kind: 'input'}).glyph, '⌨');   // 글리프 없는 제목은 kind 로
});

test('발자국 그래프: 비슷한 지문은 같은 화면(11개), 시트 닫기와 쿠폰은 되돌아가는 간선, 나머지는 층이 내려간다', () => {
  const g = P.layers(P.screens(yeogiWalk));
  assert.equal(g.nodes.length, 11); assert.equal(g.edges.length, 12);
  assert.deepEqual(g.edges.filter((e) => e.back).map((e) => e.glyph), ['⎋', '🎟']);
  assert.ok(g.edges.filter((e) => !e.back).every((e) => e.to.layer > e.from.layer));
  const rooms = g.nodes.find((n) => n.label.startsWith('객실'));
  assert.equal(rooms.in, 2);   // 호텔에서 온 길 + 시트에서 돌아온 길
  assert.equal(g.nodes.filter((n) => n.layer === 6).length, 2);   // 요금 상세 | 로그인 이 나란히
  assert.equal(P.jaccard(['a', 'b', 'c'], ['b', 'c', 'd']), 0.5);
});

test('걸어 본 단계: 글리프가 같고 대상이 맞는 성공 발자국이 있는 단계만', () => {
  const t = P.tree(manifest('yeogi').capabilities);
  assert.deepEqual(t.nodes.map((n) => !!P.walked(n, yeogiWalk)), [true, true, true, true, true, true, true, false, false, true]);   // 🔍결제수단·✋승인은 발자국 없음
  const only = (i) => [{...yeogiWalk[i], verified: {ok: 0, fail: 2}}];   // 실패만 있는 발자국은 걸은 것이 아니다
  assert.equal(P.walked(t.nodes[3], only(7)), null);
  assert.equal(P.walked(t.nodes[1], yeogiWalk).target, '^검색$');   // '최근 본 상품|검색' 의 택일이 ^검색$ 에 맞는다
  assert.ok(P.tree(manifest('hometax').capabilities).nodes.every((n) => !P.walked(n, [])));
});

test('html: 명세 나무·발자국 그래프 SVG, 발자국이 없으면 안내 한 줄, 대상 이름', () => {
  const h = P.html({manifest: manifest('yeogi'), footprints: yeogiWalk});
  assert.ok(h.includes('class="pb-tree"') && h.includes('class="pb-walks"') && !h.includes('undefined'));
  assert.ok(h.includes('걸음 12') && h.includes('화면 11') && h.includes('재생 성공 8'));
  const h2 = P.html({manifest: manifest('gov24'), footprints: []});
  assert.ok(h2.includes('pb-tree') && h2.includes('아직 걸은 적 없음') && h2.includes('Windows') && h2.includes('data-cap="check-benefits"'));
  assert.ok(P.html({manifest: manifest('hometax'), footprints: [], cap: 'cash-receipt-history'}).includes('opacity=".3"'));
});
