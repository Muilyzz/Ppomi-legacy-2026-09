import {fn} from 'storybook/test';
import './evidence-fleet.js';
import {title, here, fleet, items, pick} from './evidence-fleet-fixture.js';
const Evidence = globalThis.Evidence;

export default {
  title: '증빙/Preview',
  parameters: {layout: 'fullscreen'},
  render: (args) => { const el = document.createElement('div'); Evidence.Preview.mount(el, args); return el; },
  argTypes: {
    here: {control: 'select', options: ['mac', 'win', 'phone'], description: '이 기기'},
    fleet: {table: {disable: true}}, items: {table: {disable: true}},
    hover: {table: {disable: true}}, session: {table: {disable: true}}, inflight: {table: {disable: true}},
  },
  args: {title, here, fleet, items: pick(['ev_tax_001']), hover: 'ev_tax_001', onOpen: fn()},
};

export const Hover = {name: 'hover · 미리보기'};
export const Spinner = {name: '수신 중 · 스피너', args: {hover: 'ev_card_002', inflight: {ev_card_002: true}, items: pick(['ev_card_002'])}};
export const EncryptedCache = {name: '오프라인 · 암호문 캐시', args: {hover: 'ev_step_1', items: pick(['ev_step_1'])}};
export const SessionCache = {name: '세션 캐시 · re-hover 즉시', args: {hover: 'ev_card_002', session: {ev_card_002: true}, items: pick(['ev_card_002'])}};
export const Detached = {name: '미부착 · 빈 미리보기', args: {hover: 'ev_gone_1', items: []}};
