// 값 종류/Treemap — 계층만. path 를 깊이에서 접고 amount 크기로 가른다.
import {fn} from 'storybook/test';
import '../Ppomi/Sources/Ppomi/Web/facts.js';
import {building, holdings} from './facts-fixture.js';
const Facts = globalThis.Facts;

export default {
  title: '값 종류/Treemap',
  render: (args) => { const el = document.createElement('div'); Facts.Treemap.mount(el, args); return el; },
  argTypes: {
    depth: {control: {type: 'number', min: 1}, description: '트리맵 깊이'},
    root: {control: 'text', description: '트리맵 뿌리 경로'},
    selected: {control: 'text', description: '선택한 경로'},
    records: {table: {disable: true}}, schema: {table: {disable: true}},
  },
  args: {...building, depth: 2, root: '', selected: null, onSelect: fn(), onChange: fn()},
};

export const Building = {name: '건축물대장 · 층·호 면적'};
export const BuildingDrill = {name: '건축물대장 · 2층으로 내려감', args: {root: '건물/2층', depth: 1}};
export const Holdings = {name: '보유 종목 · 분류 평가액', args: {...holdings, depth: 2, selected: '주식/해외/ETF'}};
