// 키체인/로컬 시크릿 트리. 기본은 마스킹·접힘. 스토리북의「인증하고 열기」는 step-up 흉내(Face ID 없음).
// 앱 셸 wire는 MZZ-44 이후. https://linear.app/muilyzz/issue/MZZ-51
import {fn} from 'storybook/test';
import './secrets.js';
import blob from './secrets-fixture.json';
const S = globalThis.Secrets;

export default {
  title: '시크릿',
  render: (args) => { const el = document.createElement('div'); S.mount(el, args); return el; },
  argTypes: {
    unlocked: {control: 'boolean', description: 'step-up 후 원문'},
    expanded: {control: 'boolean', description: '트리 펼침'},
    blob: {table: {disable: true}},
  },
  args: {blob, unlocked: false, expanded: false, onUnlock: fn(), onCopy: fn()},
};

export const Locked = {name: '잠김 · 마스킹 · 접힘'};
export const Unlocked = {name: '열림 · 원문 트리', args: {unlocked: true, expanded: true}};
