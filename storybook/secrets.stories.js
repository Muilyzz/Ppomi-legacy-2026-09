// 키체인/로컬 시크릿 트리. 기본은 마스킹·접힘. 스토리북의「인증하고 열기」는 step-up 흉내(Face ID 없음).
// 뒷 4자리는 계좌 키 허용 목록(accountKeys)의 잎만; 그 외 숫자 값은 ••••. 앱 셸 wire는 MZZ-44 이후. https://linear.app/muilyzz/issue/MZZ-51
import {fn} from 'storybook/test';
import './secrets.js';
import blob from './secrets-fixture.json';
const S = globalThis.Secrets;

// 액션 패널에는 원문을 남기지 않는다: 경로와 잠김 표기(****뒷4 또는 ••••)만 기록한다.
const copied = fn();
const onCopy = (path, value) => copied(path, S.maskLeaf(path, value));

export default {
  title: '시크릿',
  render: (args) => { const el = document.createElement('div'); S.mount(el, args); return el; },
  argTypes: {
    unlocked: {control: 'boolean', description: 'step-up 후 원문'},
    expanded: {control: 'boolean', description: '트리 펼침'},
    accountKeys: {control: 'object', description: '뒷 4자리를 보이는 계좌 키 허용 목록(마지막 토큰, 대소문자 무시)'},
    blob: {table: {disable: true}},
    onCopy: {table: {disable: true}},
  },
  args: {blob, unlocked: false, expanded: false, accountKeys: S.ACCOUNT_KEYS, onUnlock: fn(), onCopy},
};

export const Locked = {name: '잠김 · 마스킹 · 접힘'};
export const Unlocked = {name: '열림 · 원문 트리', args: {unlocked: true, expanded: true}};
