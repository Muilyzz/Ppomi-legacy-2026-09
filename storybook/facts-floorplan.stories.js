// 값 종류/Floorplan — 평면도만. place 가 다각형이면 외곽선, 위도·경도면 점. 타일 지도 없음.
import {fn} from 'storybook/test';
import '../Ppomi/Sources/Ppomi/Web/facts.js';
import {building, spending} from './facts-fixture.js';
const Facts = globalThis.Facts;

export default {
  title: '값 종류/Floorplan',
  render: (args) => { const el = document.createElement('div'); Facts.Floorplan.mount(el, args); return el; },
  argTypes: {
    selected: {control: 'text', description: '선택한 기록 ID'},
    records: {table: {disable: true}}, schema: {table: {disable: true}},
  },
  args: {...building, selected: null, onSelect: fn(), onChange: fn()},
};

export const Building = {name: '건축물대장 · 외곽선 다각형'};
export const Spending = {name: '지출 장소 · 위도·경도 점', args: {...spending}};
