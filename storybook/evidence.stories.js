// 증거 하나 · 출처 둘(은행 목록, 인바디 상세) × 태그 깊이 × 필터 × 스키마(명시 | 유도). 종이 위에 마우스를 두면 원본이 깜박이며 겹친다.
import {fn} from 'storybook/test';
import '../Ppomi/Sources/Ppomi/Web/evidence.js';
import {bank, inbody} from './screens.js';
import {lease} from './screens.js';
const E = globalThis.Evidence;

export default {
  title: '증거',
  render: (args) => { const el = document.createElement('div'); E.mount(el, args); return el; },
  argTypes: {
    depth: {control: {type: 'number', min: 1}, description: '태그 깊이 · 경로 앞에서 몇 마디'},
    tag: {control: 'text', description: '접두어 필터 · 비용/식비'},
    selected: {control: 'text', description: '선택한 기록 ID'},
    frames: {table: {disable: true}}, records: {table: {disable: true}}, schema: {table: {disable: true}},
  },
  args: {...bank, depth: 3, tag: '', selected: null, onChange: fn(), onSelect: fn()},
};

export const Bank = {name: '은행 앱 · 2장 스티치', args: {}};
export const DerivedSchema = {name: '스키마 유도 · 필드 키 그대로', args: {schema: null}};
export const Depth1 = {name: '태그 깊이 1 · 유형만', args: {depth: 1}};
export const Leaf = {name: '태그 깊이 4 · 커스텀 세부까지', args: {depth: 4}};
export const Filter = {name: '태그 필터 · 비용/식비', args: {tag: '비용/식비', depth: 4}};
export const Selected = {name: '선택된 기록', args: {selected: 'tx-3'}};
export const OneFrame = {name: '화면 한 장', args: {frames: [bank.frames[0]], records: bank.records.filter((r) => r.anchors.every((a) => a.frame === 0))}};
export const InBody = {name: '인바디 · 명시 스키마', args: {...inbody, depth: 3}};
export const LeaseContract = {name: '임대차 계약서 · 2페이지', args: {...lease, depth: 4}};
