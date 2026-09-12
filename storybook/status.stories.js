// 「상태·비밀」 큰 면. 유휴 요약 + 시크릿 슬롯. 앱 셸 wire는 MZZ-54. https://linear.app/muilyzz/issue/MZZ-59
import {fn} from 'storybook/test';
import './secrets.js';
import './status.js';
import blob from './secrets-fixture.json';
import {title, phase, surfaces} from './status-fixture.js';
const S = globalThis.Status;
const Sec = globalThis.Secrets;

const copied = fn();
const onCopy = (path, value) => copied(path, Sec.maskLeaf(path, value));

export default {
  title: '상태',
  parameters: {layout: 'fullscreen'},
  render: (args) => { const el = document.createElement('div'); S.mount(el, args); return el; },
  argTypes: {
    phase: {control: 'select', options: Object.keys(S.PHASE), description: '유휴 · 연결 · 진행'},
    unlocked: {control: 'boolean', description: '시크릿 step-up 후 원문'},
    expanded: {control: 'boolean', description: '시크릿 트리 펼침'},
    title: {control: 'text'},
    blob: {table: {disable: true}},
    surfaces: {table: {disable: true}},
    onCopy: {table: {disable: true}},
  },
  args: {title, phase, surfaces, blob: null, unlocked: false, expanded: false, onUnlock: fn(), onCopy},
};

export const Idle = {name: '유휴 · 큰 면'};
export const Locked = {name: '시크릿 잠김', args: {blob, unlocked: false, expanded: false}};
export const Unlocked = {name: '시크릿 열림', args: {blob, unlocked: true, expanded: true}};
