import {fn} from 'storybook/test';
import './evidence-fleet.js';
import {title, here, fleet} from './evidence-fleet-fixture.js';
const F = globalThis.EvidenceFleet;

export default {
  title: '증빙/Presence',
  parameters: {layout: 'fullscreen'},
  render: (args) => { const el = document.createElement('div'); F.Presence.mount(el, args); return el; },
  argTypes: {
    here: {control: 'select', options: ['mac', 'win', 'phone'], description: '이 기기'},
    fleet: {table: {disable: true}},
  },
  args: {title, here, fleet, onOpen: fn()},
};

export const Devices = {name: '기기 presence · Mac/Win/Phone'};
export const Empty = {name: '기기 없음', args: {fleet: []}};
