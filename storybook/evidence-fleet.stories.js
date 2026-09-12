// 증빙 잠금 큰 면. OCR 스티치(증거)는 그대로 두고, 여기만 presence·링크·적격/보조. 앱 wire 없음. https://linear.app/muilyzz/issue/MZZ-60
import {fn} from 'storybook/test';
import './evidence-fleet.js';
import {title, here, fleet, server, items, layers, pick} from './evidence-fleet-fixture.js';
const F = globalThis.EvidenceFleet;

export default {
  title: '증빙',
  parameters: {layout: 'fullscreen'},
  render: (args) => { const el = document.createElement('div'); F.mount(el, args); return el; },
  argTypes: {
    here: {control: 'select', options: ['mac', 'win', 'phone'], description: '이 기기'},
    title: {control: 'text'},
    fleet: {table: {disable: true}}, items: {table: {disable: true}},
    server: {table: {disable: true}}, layers: {table: {disable: true}},
  },
  args: {title, here, fleet, server, items, layers, onOpen: fn()},
};

export const Panel = {name: '큰 면 · 잠금'};
export const LocalOpen = {name: '로컬 · 즉시 열기', args: {items: pick(['ev_tax_001', 'ev_cash_003']), layers: []}};
export const PeerOnline = {name: '피어 온라인 · E2E', args: {items: pick(['ev_card_002', 'ev_bill_004']), layers: []}};
export const PeerOffline = {name: '피어 오프라인 · 비활성', args: {items: pick(['ev_snap_1']), layers: []}};
export const Eligible = {name: '적격 · 연결/미연결', args: {items: pick(['ev_tax_001', 'ev_card_002', 'ev_cash_003', 'ev_bill_004']), layers: []}};
export const Auxiliary = {name: '보조만 · 스냅샷·StepResult', args: {items: pick(['ev_snap_1', 'ev_step_1']), layers: []}};
export const Presence = {name: '기기 presence · Mac/Win/Phone', args: {items: [], layers: [], server: {memo: '서버 메타만', evidence_ids: []}}};
