import {fn} from 'storybook/test';
import './evidence-fleet.js';
import {title, here, fleet, items, pick} from './evidence-fleet-fixture.js';
const Evidence = globalThis.Evidence;

export default {
  title: '증빙/Links',
  parameters: {layout: 'fullscreen'},
  render: (args) => { const el = document.createElement('div'); Evidence.Links.mount(el, args); return el; },
  argTypes: {
    here: {control: 'select', options: ['mac', 'win', 'phone'], description: '이 기기'},
    debug: {control: 'boolean', description: '내부 id'},
    fleet: {table: {disable: true}}, items: {table: {disable: true}},
    hover: {table: {disable: true}}, session: {table: {disable: true}}, inflight: {table: {disable: true}},
  },
  args: {title, here, fleet, items, debug: false, onOpen: fn()},
};

export const FourStates = {name: '링크 4상태'};
export const LocalOpen = {name: '로컬 · 즉시 열기', args: {items: pick(['ev_tax_001', 'ev_cash_003'])}};
export const PeerOnline = {name: '피어 온라인 · E2E', args: {items: pick(['ev_card_002', 'ev_bill_004'])}};
export const PeerOffline = {name: '피어 오프라인 · 비활성', args: {items: pick(['ev_snap_1'])}};
export const Eligible = {name: '적격 · 연결/미연결', args: {items: pick(['ev_tax_001', 'ev_card_002', 'ev_cash_003', 'ev_bill_004'])}};
export const Auxiliary = {name: '보조만 · 스냅샷·StepResult', args: {items: pick(['ev_snap_1', 'ev_step_1'])}};
