// 값 종류/Table — 표만. 스키마 칸 종류(수량·비율·출처·참조·이미지)는 여기 칸 렌더가 맡는다.
import {fn} from 'storybook/test';
import '../Ppomi/Sources/Ppomi/Web/facts.js';
import {building, car, holdings} from './facts-fixture.js';
const Facts = globalThis.Facts;

export default {
  title: '값 종류/Table',
  render: (args) => { const el = document.createElement('div'); Facts.Table.mount(el, args); return el; },
  argTypes: {
    selected: {control: 'text', description: '선택한 기록 ID'},
    records: {table: {disable: true}}, schema: {table: {disable: true}},
  },
  args: {...building, selected: null, onSelect: fn(), onChange: fn()},
};

export const Building = {name: '건축물대장 · 층·면적·지분 칸'};
export const Car = {name: '자동차등록증 · 참조 번호판', args: {...car}};
export const Holdings = {name: '보유 종목 · 비중 meter', args: {...holdings, selected: 'h4'}};
