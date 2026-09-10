// journal.js 의 논리 검사 — 창, 이동, 선택, 접기, 상계, 표기, 마크업. DOM 없이 돈다: npm test
import test from 'node:test';
import assert from 'node:assert/strict';
import '../Ppomi/Sources/Ppomi/Web/journal.js';
import {archive, MONEY, TIME, USD, EDU_EVENT} from './fixture.js';
const J = globalThis.Journal;
const KRW = {symbol: '원', scale: 0};

test('창: 주는 월요일 시작, 끝은 배타. 사건·전체는 창이 없다', () => {
  const [s, e] = J.span('week', '2026-09-10');   // 목요일
  assert.equal(s.getDay(), 1); assert.equal(s.getDate(), 7); assert.equal(e.getDate(), 14);
  assert.deepEqual(J.span('quarter', '2026-11-30').map(d => d.getMonth()), [9, 0]);
  assert.deepEqual(J.span('half', '2026-05-01').map(d => d.getMonth()), [0, 6]);
  assert.equal(J.span('all', '2026-01-01'), null);
  assert.equal(J.span('event', 'ev1'), null);
});

test('이동: 달·해 경계를 넘고 제목이 따라온다', () => {
  assert.equal(J.title('month', J.shift('month', '2026-12-31', 1)), '2027년 1월');
  assert.equal(J.title('day', J.shift('day', '2026-03-01', -1)), '2026-02-28 (토)');
  assert.equal(J.title('half', J.shift('half', '2026-09-08', -1)), '2026년 상반기');
  assert.equal(J.title('quarter', '2026-09-08'), '2026년 3분기');
  assert.equal(J.title('week', '2026-09-10'), '2026-09-07 ~ 09-13');
  assert.equal(J.title('all', '2026-09-10'), '전체');
});

test('선택: 원본 + 체인마다 마지막 평가 하나. 대체된 평가는 빠진다', () => {
  const rec = J.activeEntries(archive, MONEY, 'recorded'), eff = J.activeEntries(archive, MONEY, 'effective');
  assert.ok(rec.every(e => e.layer === 'recorded'));
  const adj = eff.filter(e => e.layer === 'adjustment');
  assert.equal(adj.length, 2);   // 1월 체인의 최신 + 5월
  const replaced = new Set(archive.entries.map(e => e.assessment?.replacesEntryID).filter(Boolean));
  assert.equal(replaced.size, 1);
  assert.ok(adj.every(e => !replaced.has(e.id)));
  for (let i = 1; i < eff.length; i++) assert.ok(Date.parse(eff[i - 1].occurredAt) <= Date.parse(eff[i].occurredAt));
});

test('집계: 스코프 전체가 차대 맞는 분개 하나. 같은 계정은 상계, 유형 순 정렬', () => {
  const accounts = [{id: 'a', bookID: 'b', name: '예금', kind: 'asset'}, {id: 'x', bookID: 'b', name: '비용', kind: 'expense'}, {id: 'i', bookID: 'b', name: '수익', kind: 'income'}];
  const entries = [
    {postings: [{accountID: 'x', side: 'debit', amount: 100}, {accountID: 'a', side: 'credit', amount: 100}]},
    {postings: [{accountID: 'a', side: 'debit', amount: 30}, {accountID: 'i', side: 'credit', amount: 30}]},
  ];
  const g = J.aggregate(entries, accounts, 1);
  assert.deepEqual(g.debit.map(r => [r.account.name, r.amount]), [['비용', 100]]);
  assert.deepEqual(g.credit.map(r => [r.account.name, r.amount]), [['예금', 70], ['수익', 30]]);
  assert.equal(g.debitTotal, 100); assert.equal(g.creditTotal, 100); assert.equal(g.count, 2);
  assert.deepEqual(J.aggregate([], accounts, 1), {debit: [], credit: [], debitTotal: 0, creditTotal: 0, count: 0});
});

test('깊이: 0 = 유형, 1 = 뿌리, 계층보다 깊으면 잎. 모르는 ID는 그대로', () => {
  const at = d => J.rollup(archive.accounts, d);
  assert.equal(at(0)('x-lunch').name, '비용'); assert.equal(at(0)('x-lunch').id, 'kind:expense');
  assert.equal(at(1)('x-lunch').name, '비용');
  assert.equal(at(2)('x-lunch').name, '식비');
  assert.deepEqual(at(Infinity)('x-lunch'), {id: 'x-lunch', name: '점심', kind: 'expense', path: ['비용', '식비']});
  assert.equal(at(3)('x-edu').name, '교육비');   // 2단 계정은 3에서도 자신
  assert.equal(at(2)('ghost').name, 'ghost');
  assert.equal(J.maxDepth(archive.accounts, MONEY), 3);
  assert.equal(J.maxDepth(archive.accounts, TIME), 1);
});

test('표기: 최소단위 정수 → 소수 자리는 문자열로', () => {
  assert.equal(J.amount(1234567, KRW), '1,234,567 원');
  assert.equal(J.amount(1299, {symbol: '$', scale: 2}), '12.99 $');
  assert.equal(J.amount(5, {symbol: '$', scale: 2}), '0.05 $');
  assert.equal(J.amount(0, KRW), '0 원');
  assert.equal(J.amount(-100, KRW), '−100 원');
});

test('픽스처: 모든 장부·층·스코프·깊이에서 차대 일치, 분개마다 차대 일치', () => {
  for (const bookID of [MONEY, TIME, USD]) for (const layer of ['recorded', 'effective']) for (const unit of J.UNITS.slice(1)) for (const depth of [0, 1, 2, 3]) {
    const g = J.aggregate(J.inScope(J.activeEntries(archive, bookID, layer), unit, '2026-09-08'), archive.accounts, depth);
    assert.equal(g.debitTotal, g.creditTotal, `${bookID} ${layer} ${unit} ${depth}`);
  }
  for (const e of archive.entries) assert.equal(e.postings.reduce((s, p) => s + (p.side === 'debit' ? p.amount : -p.amount), 0), 0, e.id);
  assert.ok(new Set(archive.entries.map(e => e.id)).size === archive.entries.length);
});

test('사건 스코프: eventID 하나에 원본과 유효한 조정이 함께', () => {
  const scoped = J.inScope(J.activeEntries(archive, MONEY, 'effective'), 'event', EDU_EVENT);
  assert.equal(scoped.filter(e => e.layer === 'recorded').length, 1);
  assert.equal(scoped.filter(e => e.layer === 'adjustment').length, 1);
  const g = J.aggregate(scoped, archive.accounts, 3);
  assert.deepEqual(g.debit.map(r => [r.account.name, r.amount]), [['역량 · 관리용 추정', 180000], ['교육비', 120000]]);
  assert.deepEqual(g.credit.map(r => [r.account.name, r.amount]), [['KB국민', 300000]]);
});

test('마크업: 표 하나 + 목록, 빈 스코프와 사건은 다르게', () => {
  const base = {archive, bookID: MONEY, at: '2026-09-08', depth: 2, layer: 'recorded'};
  const month = J.html({...base, unit: 'month'});
  assert.match(month, /<h2 class="key">2026년 9월<\/h2>/);
  assert.match(month, /<table class="journal"/);
  assert.match(month, /<table class="entries"/);
  assert.equal((month.match(/<style/g) || []).length, 0);   // 꾸밈은 밖에서
  assert.match(month, /data-unit="month" class="on" aria-pressed="true"/);
  assert.match(J.html({...base, unit: 'day', at: '2024-01-01'}), /분개가 없습니다/);
  const event = J.html({...base, unit: 'event', at: EDU_EVENT, layer: 'effective'});
  assert.match(event, /온라인 강의 · 교육비<\/h2>/);
  assert.match(event, /평가 조정 · 신뢰도 55%/);
  assert.match(event, /이전 평가 e\d+ 대체/);
  assert.doesNotMatch(event, /<table class="entries"/);
  assert.match(J.html({...base, bookID: 'nope'}), /장부를 찾을 수 없습니다/);
});
