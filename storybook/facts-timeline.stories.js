// 값 종류/Timeline — 시간축만. time 필드가 점, until 이 있으면 막대.
import {fn} from 'storybook/test';
import '../Ppomi/Sources/Ppomi/Web/facts.js';
import {building, loan, car} from './facts-fixture.js';
const X = globalThis.Facts;

export default {
  title: '값 종류/Timeline',
  render: (args) => { const el = document.createElement('div'); X.Timeline.mount(el, args); return el; },
  argTypes: {
    selected: {control: 'text', description: '선택한 기록 ID'},
    records: {table: {disable: true}}, schema: {table: {disable: true}},
  },
  args: {...loan, selected: null, onSelect: fn(), onChange: fn()},
};

export const Loan = {name: '대출 약정 · 기간 막대 + 회차 점'};
export const Car = {name: '자동차등록증 · 등록·보험·정비', args: {...car}};
export const Building = {name: '건축물대장 · 사용승인일', args: {...building}};
