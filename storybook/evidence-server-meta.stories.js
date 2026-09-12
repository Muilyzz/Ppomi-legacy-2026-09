import {fn} from 'storybook/test';
import './evidence-fleet.js';
import {title, here, fleet, server, items} from './evidence-fleet-fixture.js';
const F = globalThis.EvidenceFleet;

export default {
  title: '증빙/ServerMeta',
  parameters: {layout: 'fullscreen'},
  render: (args) => { const el = document.createElement('div'); F.ServerMeta.mount(el, args); return el; },
  argTypes: {
    debug: {control: 'boolean', description: '내부 id'},
    fleet: {table: {disable: true}}, items: {table: {disable: true}}, server: {table: {disable: true}},
  },
  args: {title, here, fleet, server, items, debug: false, onOpen: fn()},
};

export const Journal = {name: '분개 · 숫자 · 메타 링크'};
export const MetaOnly = {name: '서버 메타만', args: {items: [], server: {memo: '서버 메타만', evidence_ids: []}}};
