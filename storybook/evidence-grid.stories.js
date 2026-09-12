import {fn} from 'storybook/test';
import './evidence-fleet.js';
import {title, here, fleet, items, server} from './evidence-fleet-fixture.js';
const F = globalThis.EvidenceFleet;

export default {
  title: '증빙/Grid',
  parameters: {layout: 'fullscreen'},
  render: (args) => { const el = document.createElement('div'); F.Grid.mount(el, args); return el; },
  argTypes: {
    here: {control: 'select', options: ['mac', 'win', 'phone'], description: '이 기기'},
    fleet: {table: {disable: true}}, items: {table: {disable: true}}, server: {table: {disable: true}},
    hover: {table: {disable: true}},
  },
  args: {title, here, fleet, items, server, onOpen: fn()},
};

export const DeviceTime = {name: '기기×시각'};
export const FilledOnline = {name: '온라인 채움', args: {items: items.filter((it) => it.host === 'mac' || it.host === 'win')}};
export const EmptyOffline = {name: '오프라인 빈 칸', args: {items: items.filter((it) => it.host === 'phone')}};
