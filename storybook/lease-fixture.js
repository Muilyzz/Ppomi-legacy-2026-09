// storybook/lease-fixture.js — 임대 하나를 세 사실로: 계약(속성) · 임대 분개(이동) · 약정 대조(관측 vs 약정). 호실 경로가 셋을 잇는다. 전부 가상.
// 호실은 계정 밑의 커스텀 세부 계정이다: 수익/임대료/건물/2층/201호, 부채/임대보증금/건물/2층/201호. 임차인은 ref ID 만 — 신원 정보는 기록에 넣지 않는다.
import '../Ppomi/Sources/Ppomi/Web/journal.js';
const J = globalThis.Journal;
export const TODAY = '2026-09-10', BOOK = 'lease-money';
const OWNER = 'demo-person', BIZ = 'demo-rental';

// ---- 계약 3건(속성)
const F = (key, title, type, extra) => ({key, title, type, ...extra});
export const contractSchema = {fields: [F('unit', '호실', 'path'), F('tenant', '임차인', 'ref'), F('from', '계약 시작', 'time', {until: 'to'}), F('to', '계약 만기', 'time'),
  F('deposit', '보증금', 'amount', {unit: '원'}), F('rent', '월세', 'amount', {unit: '원'}), F('day', '납부일', 'text'), F('prov', '출처', 'provenance')]};
export const contracts = [
  {id: 'c-201', fields: {unit: '건물/2층/201호', tenant: 'tenant-kim', from: '2025-03-01', to: '2027-02-28', deposit: 20000000, rent: 900000, day: '매월 5일', prov: 'ocr'}},
  {id: 'c-202', fields: {unit: '건물/2층/202호', tenant: 'tenant-park', from: '2026-01-15', to: '2028-01-14', deposit: 30000000, rent: 700000, day: '매월 15일', prov: 'ocr'}},
  {id: 'c-301', fields: {unit: '건물/3층/301호', tenant: 'tenant-lee', from: '2024-07-01', to: '2026-06-30', deposit: 10000000, rent: 650000, day: '매월 1일', prov: 'manual'}},
];
const DAY = {'c-201': 5, 'c-202': 15, 'c-301': 1};

// ---- 임대 장부(이동): 사업 장부. 보증금은 부채, 월세는 수익.
const A = [['a', '자산', 'asset'], ['a-bank', '예금', 'asset', 'a'],
  ['l', '부채', 'liability'], ['l-dep', '임대보증금', 'liability', 'l'], ['l-b', '건물', 'liability', 'l-dep'], ['l-b2', '2층', 'liability', 'l-b'], ['l-201', '201호', 'liability', 'l-b2'], ['l-202', '202호', 'liability', 'l-b2'], ['l-b3', '3층', 'liability', 'l-b'], ['l-301', '301호', 'liability', 'l-b3'],
  ['i', '수익', 'income'], ['i-rent', '임대료', 'income', 'i'], ['i-b', '건물', 'income', 'i-rent'], ['i-b2', '2층', 'income', 'i-b'], ['i-201', '201호', 'income', 'i-b2'], ['i-202', '202호', 'income', 'i-b2'], ['i-b3', '3층', 'income', 'i-b'], ['i-301', '301호', 'income', 'i-b3'],
  ['x', '비용', 'expense'], ['x-repair', '수선비', 'expense', 'x']];
const accounts = A.map(([id, name, kind, parentID]) => parentID ? {id, bookID: BOOK, name, kind, parentID} : {id, bookID: BOOK, name, kind});
const entries = []; let n = 0;
const post = (date, memo, lines) => { const id = 'r' + (++n), iso = date + 'T03:00:00Z'; entries.push({id, eventID: 'ev-' + id, bookID: BOOK, occurredAt: iso, recordedAt: iso, memo, source: 'synthetic-lease', sourceRecordID: id, postings: lines.map(([accountID, side, amount]) => ({accountID, side, amount})), layer: 'recorded'}); };
const rent = (unit, date, amount) => post(date, unit.slice(-4) + ' 월세', [['a-bank', 'debit', amount], [{'201호': 'i-201', '202호': 'i-202', '301호': 'i-301'}[unit.slice(-4)], 'credit', amount]]);
const md = (y, m, d) => `${y}-${String(m).padStart(2, '0')}-${String(d).padStart(2, '0')}`;
post('2024-07-01', '301호 보증금 수령', [['a-bank', 'debit', 10000000], ['l-301', 'credit', 10000000]]);
post('2025-03-01', '201호 보증금 수령', [['a-bank', 'debit', 20000000], ['l-201', 'credit', 20000000]]);
post('2026-01-15', '202호 보증금 수령', [['a-bank', 'debit', 30000000], ['l-202', 'credit', 30000000]]);
post('2026-06-30', '301호 보증금 반환', [['l-301', 'debit', 10000000], ['a-bank', 'credit', 10000000]]);
post('2026-07-03', '301호 도배', [['x-repair', 'debit', 480000], ['a-bank', 'credit', 480000]]);
for (let k = 0; k < 24; k++) rent('301호', md(2024 + Math.floor((6 + k) / 12), (6 + k) % 12 + 1, 1), 650000);          // 2024-07 ~ 2026-06 전부 1일 납부
for (let k = 0; k < 19; k++) {                                                                                        // 2025-03 ~ 2026-09
  const y = 2025 + Math.floor((2 + k) / 12), m = (2 + k) % 12 + 1, ym = md(y, m, 1).slice(0, 7);
  if (ym === '2026-07') continue;                                                                                     // 미납
  rent('201호', ym === '2025-11' ? md(y, m, 7) : ym === '2026-08' ? md(y, m, 21) : md(y, m, 5), 900000);              // 11월 이틀 늦음, 8월 16일 연체
}
for (let k = 0; k < 8; k++) { const m = k + 1, ym = md(2026, m, 1).slice(0, 7); rent('202호', md(2026, m, 15), ym === '2026-06' ? 400000 : 700000); }   // 6월 부분납 · 9월은 예정
export const archive = {formatVersion: 1, books: [{id: BOOK, name: '가상 · 임대 사업', ownerID: OWNER, scope: {kind: 'business', ownerID: OWNER, businessID: BIZ}, kind: 'financial', unit: {id: 'KRW', name: '대한민국 원', symbol: '원', dimension: 'currency', scale: 0}}], accounts, entries};

// ---- 약정 대조 입력: 분개의 수익 대변 항목을 계정 잎 경로로 편다. 규칙의 경로 = 그 호실의 임대료 계정.
const leaf = J.rollup(accounts, Infinity);
export const rentEntries = J.activeEntries(archive, BOOK, 'recorded').flatMap((e) => e.postings.filter((p) => p.side === 'credit' && leaf(p.accountID).kind === 'income')
  .map((p) => { const a = leaf(p.accountID); return {at: e.occurredAt.slice(0, 10), path: a.path.concat(a.name).join('/'), amount: p.amount}; }));
export const rules = contracts.map((c) => ({id: c.id, path: '수익/임대료/' + c.fields.unit, day: DAY[c.id], amount: c.fields.rent, from: c.fields.from, to: c.fields.to, label: c.fields.unit.slice(-4) + ' 월세'}));
