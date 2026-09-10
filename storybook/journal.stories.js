// 분개 하나 · 스코프 8개 × 깊이 × 층. 컨트롤로 아무 조합이나 만들고, 툴바 '스타일'로 기본 DOM / 뽀미 테마를 오간다.
import {fn} from 'storybook/test';
import '../Ppomi/Sources/Ppomi/Web/journal.js';
import example from '../Ppomi/Sources/Ppomi/AccountingData/example.json';
import {archive, MONEY, TIME, USD, EDU_EVENT} from './fixture.js';
import {archive as leaseArchive, BOOK as LEASE_BOOK} from './lease-fixture.js';
const J = globalThis.Journal;

export default {
  title: '분개',
  render: (args) => { const el = document.createElement('div'); J.mount(el, args); return el; },
  argTypes: {
    unit: {control: 'select', options: J.UNITS, description: '스코프'},
    at: {control: 'text', description: "'YYYY-MM-DD' · 사건이면 eventID"},
    depth: {control: {type: 'number', min: 0}, description: '계정 깊이 · 0 = 유형'},
    layer: {control: 'radio', options: ['recorded', 'effective'], description: '원본만 · 유효한 평가 조정까지'},
    bookID: {control: 'select', options: [MONEY, TIME, USD]},
    archive: {table: {disable: true}},
  },
  args: {archive, bookID: MONEY, unit: 'month', at: '2026-09-08', depth: 2, layer: 'recorded', onChange: fn()},
};

export const Event = {name: '사건', args: {unit: 'event', at: EDU_EVENT, depth: 3, layer: 'effective'}};
export const Day = {name: '일', args: {unit: 'day', depth: 3}};
export const Week = {name: '주', args: {unit: 'week', depth: 3}};
export const Month = {name: '월', args: {unit: 'month'}};
export const Quarter = {name: '분기', args: {unit: 'quarter'}};
export const Half = {name: '반기', args: {unit: 'half'}};
export const Year = {name: '년', args: {unit: 'year', depth: 1}};
export const All = {name: '전체', args: {unit: 'all', depth: 0}};
export const DeepestAccounts = {name: '깊이 · 잎까지', args: {unit: 'year', depth: 3}};
export const Effective = {name: '관리 · 평가 포함', args: {unit: 'month', at: '2026-01-15', depth: 3, layer: 'effective'}};
export const Empty = {name: '빈 스코프', args: {unit: 'day', at: '2024-01-01'}};
export const TimeBook = {name: '시간 장부 · 분', args: {bookID: TIME, unit: 'week', depth: 1, layer: 'effective'}};
export const Fractional = {name: '소수 단위 · 달러', args: {bookID: USD, unit: 'all', depth: 1}};
export const BundledExample = {name: '번들 예시 · example.json', args: {archive: example, bookID: 'example-money', unit: 'all', depth: 2, layer: 'effective'}};
export const Lease = {name: '임대 장부 · 2026년 8월 · 호실 세부계정까지', args: {archive: leaseArchive, bookID: LEASE_BOOK, unit: 'month', at: '2026-08-01', depth: 5}};
