// 값 종류 뷰 — 대장 다섯 개 + 분개 집계 하나가 전부 같은 Facts.mount 를 쓴다. 에이전트가 {records, schema} 만 돌려주면 이 화면이 된다.
import {fn} from 'storybook/test';
import '../Ppomi/Sources/Ppomi/Web/facts.js';
import '../Ppomi/Sources/Ppomi/Web/journal.js';
import '../Ppomi/Sources/Ppomi/Web/schedule.js';
import {building, loan, car, spending, holdings} from './facts-fixture.js';
import {archive, MONEY} from './fixture.js';
import {contracts, contractSchema, rules, rentEntries, TODAY} from './lease-fixture.js';
import {parseGovSites, govSchema} from './gov-fixture.js';
import govMd from '../docs/gov-sites.md?raw';
const X = globalThis.Facts, J = globalThis.Journal, S = globalThis.Schedule;

// 분개 → 값 종류: 비용 차변 항목을 계정 경로 + 금액으로. 도메인 코드 없이 트리맵이 된다.
const leaf = J.rollup(archive.accounts, Infinity);
const expenses = {
  schema: {fields: [F('path', '계정', 'path'), F('amount', '금액', 'amount', {unit: '원'}), F('memo', '메모', 'text')]},
  records: J.activeEntries(archive, MONEY, 'recorded').flatMap((e) => e.postings.filter((p) => p.side === 'debit' && leaf(p.accountID).kind === 'expense')
    .map((p, i) => { const a = leaf(p.accountID); return {id: e.id + '-' + i, fields: {path: a.path.concat(a.name).join('/'), amount: p.amount, memo: e.memo}}; })),
};
function F(key, title, type, extra) { return {key, title, type, ...extra}; }

export default {
  title: '값 종류 뷰',
  render: (args) => { const el = document.createElement('div'); X.mount(el, args); return el; },
  argTypes: {
    depth: {control: {type: 'number', min: 1}, description: '트리맵 깊이'},
    root: {control: 'text', description: '트리맵 뿌리 경로'},
    selected: {control: 'text', description: '선택한 기록 ID 또는 경로'},
    records: {table: {disable: true}}, schema: {table: {disable: true}},
  },
  args: {...building, depth: 1, root: '', selected: null, onSelect: fn(), onChange: fn()},
};

export const Building = {name: '건축물대장 · 층·면적·승인일·외곽선·지분', args: {depth: 2}};
export const BuildingDrill = {name: '건축물대장 · 2층으로 내려감', args: {root: '건물/2층'}};
export const Loan = {name: '대출 약정 · 기간 막대 + 회차 점', args: {...loan, depth: 2}};
export const Car = {name: '자동차등록증 · 시간축만', args: {...car}};
export const Spending = {name: '지출 장소 · 평면도 + 트리맵 + 시간축', args: {...spending, depth: 2}};
export const Holdings = {name: '보유 종목 · 트리맵 + 비중', args: {...holdings, depth: 2, selected: 'h4'}};
export const Expenses = {name: '계정 트리맵 · 분개 1년치 비용', args: {...expenses, depth: 2}};
export const Contracts = {name: '임대차 계약 · 호실별 기간·보증금·월세', args: {records: contracts, schema: contractSchema, depth: 3}};
// 약정 대조는 뷰가 아니라 파생이다: 규칙 + 분개 → 판정 기록(출처 = 계산). 그 기록을 같은 뷰가 그린다.
export const Reconcile = {name: '약정 대조 결과 · 임대 월세 · 납부·부분납·미납·예정', args: {records: S.reconcile(rules, rentEntries, TODAY), schema: S.SCHEMA, root: '수익/임대료/건물', depth: 2}};
export const ReconcileLater = {name: '약정 대조 결과 · 기준일을 10월로', args: {records: S.reconcile(rules, rentEntries, '2026-10-20'), schema: S.SCHEMA, root: '수익/임대료/건물', depth: 2}};
// 공공사이트 트리(docs/gov-sites.md)는 문서가 원본이다. 파서가 기록으로 바꾸면 분야·부처별 사이트 수 트리맵과 표가 된다.
const gov = parseGovSites(govMd);
export const GovSites = {name: '공공사이트 트리 · docs/gov-sites.md · 분야·부처별', args: {records: gov, schema: govSchema, depth: 2}};
export const GovP1 = {name: '공공사이트 트리 · P1·P2 플레이북 후보만', args: {records: gov.filter((r) => r.fields.priority <= 'P2'), schema: govSchema, depth: 3}};
