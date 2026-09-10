// storybook/fixture.js — 가상 장부 1년치. 실제 자료가 아니다. 시드가 고정이라 스토리와 테스트가 같은 숫자를 본다.
// 형식은 AccountingData/example.json 과 같다(books · accounts · entries).
export const MONEY = 'demo-money', TIME = 'demo-time', USD = 'demo-usd';
const OWNER = 'demo-person', scope = {kind: 'personal', ownerID: OWNER};
const unit = (id, name, symbol, dimension, scale) => ({id, name, symbol, dimension, scale});
const books = [
  {id: MONEY, name: '가상 · 돈', ownerID: OWNER, scope, kind: 'financial', unit: unit('KRW', '대한민국 원', '원', 'currency', 0)},
  {id: TIME, name: '가상 · 시간', ownerID: OWNER, scope, kind: 'resource', unit: unit('min', '분', '분', 'time', 0)},
  {id: USD, name: '가상 · 달러', ownerID: OWNER, scope, kind: 'financial', unit: unit('USD', '미국 달러', '$', 'currency', 2)},
];
// [id, 이름, 유형, 상위]
const A = [
  ['a', '자산', 'asset'], ['a-bank', '예금', 'asset', 'a'], ['a-kakao', '카카오뱅크', 'asset', 'a-bank'], ['a-kb', 'KB국민', 'asset', 'a-bank'], ['a-skill', '역량 · 관리용 추정', 'asset', 'a'],
  ['l', '부채', 'liability'], ['l-card', '카드', 'liability', 'l'], ['l-shinhan', '신한카드', 'liability', 'l-card'],
  ['e', '자본', 'equity'], ['e-open', '기초자본', 'equity', 'e'],
  ['i', '수익', 'income'], ['i-salary', '급여', 'income', 'i'], ['i-interest', '이자', 'income', 'i'],
  ['x', '비용', 'expense'], ['x-food', '식비', 'expense', 'x'], ['x-lunch', '점심', 'expense', 'x-food'], ['x-cafe', '카페', 'expense', 'x-food'], ['x-delivery', '배달', 'expense', 'x-food'],
  ['x-move', '교통', 'expense', 'x'], ['x-subway', '지하철', 'expense', 'x-move'], ['x-taxi', '택시', 'expense', 'x-move'],
  ['x-home', '주거', 'expense', 'x'], ['x-rent', '월세', 'expense', 'x-home'], ['x-fee', '관리비', 'expense', 'x-home'],
  ['x-sub', '구독', 'expense', 'x'], ['x-youtube', '유튜브', 'expense', 'x-sub'], ['x-cloud', '클라우드', 'expense', 'x-sub'],
  ['x-edu', '교육비', 'expense', 'x'],
];
const T = [['t-budget', '가용시간예산', 'asset'], ['t-invest', '미상각 학습투입', 'asset'], ['t-alloc', '일일 시간배정', 'equity'], ['t-study', '학습시간 사용', 'expense'], ['t-move', '운동시간 사용', 'expense']];
const U = [['u-cash', '달러 현금', 'asset'], ['u-open', '기초자본', 'equity'], ['u-sub', '해외 구독', 'expense']];
const acct = (bookID) => ([id, name, kind, parentID]) => parentID ? {id, bookID, name, kind, parentID} : {id, bookID, name, kind};
const accounts = [...A.map(acct(MONEY)), ...T.map(acct(TIME)), ...U.map(acct(USD))];

function rng(seed) { return () => { seed |= 0; seed = seed + 0x6D2B79F5 | 0; let t = Math.imul(seed ^ seed >>> 15, 1 | seed); t = t + Math.imul(t ^ t >>> 7, 61 | t) ^ t; return ((t ^ t >>> 14) >>> 0) / 4294967296; }; }
const rand = rng(20260910);
const between = (lo, hi, step = 100) => lo + Math.floor(rand() * ((hi - lo) / step + 1)) * step;
const at = (y, m, d, h = 12, mi = 0) => new Date(y, m - 1, d, h, mi);

const entries = [];
let n = 0, card = 0;   // card: 이번 달 카드 사용 누계 → 15일 결제
function post(bookID, d, memo, lines, extra = {}) {
  const id = 'e' + (++n), iso = d.toISOString();
  const e = {id, eventID: 'ev' + n, bookID, occurredAt: iso, recordedAt: iso, memo, source: 'synthetic-demo', sourceRecordID: id,
    postings: lines.map(([accountID, side, amount]) => ({accountID, side, amount})), layer: 'recorded', ...extra};
  entries.push(e);
  return e;
}
const spend = (d, memo, account, amount, from = 'l-shinhan') => { if (from === 'l-shinhan') card += amount; return post(MONEY, d, memo, [[account, 'debit', amount], [from, 'credit', amount]]); };
const adjust = (source, d, memo, account, amount, assessment) =>
  post(MONEY, at(...d), memo, [[account, 'debit', amount], [source.postings[0].accountID, 'credit', amount]],
    {eventID: source.eventID, occurredAt: source.occurredAt, layer: 'adjustment', assessment: {sourceEntryID: source.id, model: '가상 평가자', ...assessment}});

post(MONEY, at(2025, 9, 1, 0), '기초잔액', [['a-kakao', 'debit', 3000000], ['a-kb', 'debit', 1500000], ['e-open', 'credit', 4500000]]);
for (let d = at(2025, 9, 1); d < at(2026, 9, 11); d = new Date(d.getFullYear(), d.getMonth(), d.getDate() + 1)) {
  const Y = d.getFullYear(), M = d.getMonth() + 1, D = d.getDate(), dow = d.getDay(), t = (h, mi = 0) => at(Y, M, D, h, mi);
  if (D === 1) { spend(t(9), '월세', 'x-rent', 650000, 'a-kakao'); spend(t(9, 5), '아파트 관리비', 'x-fee', between(95000, 140000), 'a-kakao'); }
  if (D === 5) { spend(t(3), '유튜브 프리미엄', 'x-youtube', 14900); spend(t(3, 1), '클라우드 저장공간', 'x-cloud', 3300); }
  if (D === 15 && card) { post(MONEY, t(10), '신한카드 결제', [['l-shinhan', 'debit', card], ['a-kb', 'credit', card]]); card = 0; }
  if (D === 25) post(MONEY, t(9), '급여', [['a-kakao', 'debit', 3200000], ['i-salary', 'credit', 3200000]]);
  if (dow >= 1 && dow <= 5) {
    if (rand() < 0.5) spend(t(8, 40), '지하철', 'x-subway', 1550);
    spend(t(12, 30), '점심', 'x-lunch', between(7000, 13000, 500));
    if (rand() < 0.6) spend(t(15, 10), '카페', 'x-cafe', between(4500, 6500));
    if (rand() < 0.06) spend(t(23, 10), '택시', 'x-taxi', between(9000, 18000));
  }
  if (dow === 6 && rand() < 0.8) spend(t(19), '배달 저녁', 'x-delivery', between(18000, 32000, 1000));
  if (M % 3 === 0 && D === new Date(Y, M, 0).getDate()) { const i = between(1500, 4000, 10); post(MONEY, t(23, 59), '예금 이자', [['a-kakao', 'debit', i], ['i-interest', 'credit', i]]); }
}
const edu = spend(at(2026, 1, 10, 10), '온라인 강의 · 교육비', 'x-edu', 300000, 'a-kb');
const first = adjust(edu, [2026, 1, 20, 9], '교육비 50% 관리상 자산화 (첫 판단)', 'a-skill', 150000, {rationale: '과정 절반 수강 시점의 추정.', confidenceBasisPoints: 3000});
adjust(edu, [2026, 3, 1, 9], '교육비 60% 관리상 자산화', 'a-skill', 180000, {rationale: '수료 후 제출물 기준으로 갱신. 설명용 가정이며 앱의 기본값이 아니다.', confidenceBasisPoints: 5500, replacesEntryID: first.id});
const edu2 = spend(at(2026, 5, 20, 14), '워크숍 참가비 · 교육비', 'x-edu', 200000, 'a-kb');
adjust(edu2, [2026, 5, 25, 9], '교육비 40% 관리상 자산화', 'a-skill', 80000, {rationale: '실무 적용 여부가 불확실해 낮게 잡음.', confidenceBasisPoints: 3500});
export const EDU_EVENT = edu.eventID;

for (let D = 1; D <= 10; D++) {
  post(TIME, at(2026, 9, D, 0), '하루 시간예산 배정', [['t-budget', 'debit', 1440], ['t-alloc', 'credit', 1440]]);
  if (D % 2) {
    const s = post(TIME, at(2026, 9, D, 21), '학습 90분', [['t-study', 'debit', 90], ['t-budget', 'credit', 90]]);
    if (D === 1 || D === 7) post(TIME, at(2026, 9, D + 1, 9), '학습 60% 미상각 투입', [['t-invest', 'debit', 54], ['t-study', 'credit', 54]],
      {eventID: s.eventID, occurredAt: s.occurredAt, layer: 'adjustment', assessment: {sourceEntryID: s.id, rationale: '미래 효용이 남았다고 보는 과거 투입량. 시간의 시장가격이 아니다.', confidenceBasisPoints: 4000, model: '가상 평가자'}});
  }
  if (rand() < 0.5) post(TIME, at(2026, 9, D, 7), '운동 45분', [['t-move', 'debit', 45], ['t-budget', 'credit', 45]]);
}
post(USD, at(2026, 9, 1, 0), '기초잔액', [['u-cash', 'debit', 100000], ['u-open', 'credit', 100000]]);
post(USD, at(2026, 9, 3, 2), 'Claude 구독', [['u-sub', 'debit', 2000], ['u-cash', 'credit', 2000]]);
post(USD, at(2026, 9, 9, 2), '도메인 갱신', [['u-sub', 'debit', 1299], ['u-cash', 'credit', 1299]]);

export const archive = {formatVersion: 1, books, accounts, entries};
