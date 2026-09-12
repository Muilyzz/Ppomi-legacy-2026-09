// 증빙/Panel — 조립만. 자식 스토리는 증빙/Presence · Links · Grid · Preview · ServerMeta.
import {fn} from 'storybook/test';
import './evidence-fleet.js';
import {title, here, fleet, server, items, layers, pick} from './evidence-fleet-fixture.js';
const F = globalThis.EvidenceFleet;

export default {
  title: '증빙/Panel',
  parameters: {layout: 'fullscreen'},
  render: (args) => { const el = document.createElement('div'); F.Panel.mount(el, args); return el; },
  argTypes: {
    here: {control: 'select', options: ['mac', 'win', 'phone'], description: '이 기기'},
    title: {control: 'text'},
    debug: {control: 'boolean', description: '내부 id'},
    fleet: {table: {disable: true}}, items: {table: {disable: true}},
    server: {table: {disable: true}}, layers: {table: {disable: true}},
    hover: {table: {disable: true}}, session: {table: {disable: true}}, inflight: {table: {disable: true}},
  },
  args: {title, here, fleet, server, items, layers, debug: false, onOpen: fn()},
};

export const Lock = {name: '큰 면 · 잠금'};
export const LocalOpen = {name: '로컬 · 즉시 열기', args: {items: pick(['ev_tax_001', 'ev_cash_003']), layers: []}};
export const PeerOnline = {name: '피어 온라인 · E2E', args: {items: pick(['ev_card_002', 'ev_bill_004']), layers: []}};
export const PeerOffline = {name: '피어 오프라인 · 비활성', args: {items: pick(['ev_snap_1']), layers: []}};
