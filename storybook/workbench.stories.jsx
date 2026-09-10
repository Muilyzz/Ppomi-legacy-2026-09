// 작업대. 상태는 셋: 대화(자리 비어 있음) · 차례 · 기록 페이지. 크기 클래스는 둘: compact(< 840px, 닫힌 폴드·작은 Mac 창) · expanded.
// 뼈대(agent/src/ui/workbench.tsx)에 서브트리를 주입하고 스타일은 툴바가 넣는다. 폭은 `width`로 고정하거나(폴드 닫힘 400 · 펼침 904) 뷰포트 툴바로 본다. 요구 장부: docs/ui-tree.md.
import React from 'react';
import {createRoot} from 'react-dom/client';
import {Workbench, ControlSlot, ControlHeader} from '../agent/src/ui/workbench';
import * as f from '../agent/src/ui/fixtures';
import '../Ppomi/Sources/Ppomi/Web/evidence.js';
import {bank} from './screens.js';

const control = (turn, line) => <>{f.controlHeader}<ControlSlot turn={turn}>{line}</ControlSlot></>;
const CLOSED = 400, OPEN = 904;   // Galaxy Fold 바깥·안쪽 화면 폭(dp) 근사. 펼침의 제어 열 = 904 − 닫힘 폭 − 간격 → 왼쪽이 닫힌 화면 그대로
const frame = (width, node) => <div style={{width, height: '100dvh', overflow: 'hidden', flex: 'none'}}>{node}</div>;

export default {
  title: '작업대',
  parameters: {skin: ['shell', 'workbench']},
  render: ({width, ...args}) => { const el = document.createElement('div'); createRoot(el).render(width ? frame(width, <Workbench {...args} />) : <Workbench {...args} />); return el; },
  argTypes: {
    width: {control: 'number', description: '작업대 폭(px) · 비우면 뷰포트'},
    targetWidth: {control: 'number', description: '대상 창 폭(px) = 제어 열 폭'},
    conversation: {table: {disable: true}}, control: {table: {disable: true}}, turn: {table: {disable: true}}, records: {table: {disable: true}},
  },
  args: {targetWidth: 300, conversation: f.conversation, control: control(false, 'iPhone · 연결 끊김')},
};

export const Talk = {name: '대화'};
export const Turn = {name: '차례', args: {control: control(true, '승인 차례'), turn: f.turn}};
export const Records = {name: '기록 페이지', args: {records: f.records}};
export const Closed = {name: 'compact · 닫힌 폴드 400 · 대화', args: {width: CLOSED}};
export const ClosedTurn = {name: 'compact · 닫힌 폴드 400 · 차례', args: {width: CLOSED, control: control(true, '승인 차례'), turn: f.turn}};
export const Open = {name: 'expanded · 펼친 폴드 904 · 제어 480', args: {width: OPEN, targetWidth: OPEN - CLOSED - 24}};
export const SideBySide = {name: '나란히 · 닫힘 | 펼침', render: (args) => {
  const el = document.createElement('div');
  createRoot(el).render(<div style={{display: 'flex', gap: '1rem', alignItems: 'flex-start'}}>
    {frame(CLOSED, <Workbench {...args} />)}{frame(OPEN, <Workbench {...args} targetWidth={OPEN - CLOSED - 24} />)}
  </div>);
  return el;
}, args: {control: control(true, '승인 차례'), turn: f.turn}};

// 아이패드: 같은 작업대, 제어 열에 대상 창 대신 장부. 머리띠의 대상 선택기 자리에 탭, 자리에 뷰 하나(여기선 증빙 = Evidence.mount). 폭을 비워 뷰포트로 보면 세로(< 840)에선 본문이 접히고 탭만 레일에 남는다.
const ledger = <>
  <style>{'body{max-width:none;padding:0}'}</style>   {/* theme.css 의 body 40rem 은 낱장 페이지용. 작업대 안에선 열이 페이지다 */}
  <ControlHeader target={<div role="tablist" aria-label="기록 종류">{f.recordTabs.slice(0, 5).map((tab, i) => <button key={tab} role="tab" aria-selected={i === 1}>{tab}</button>)}</div>} />
  <div className="records-body" ref={(el) => el && !el.firstChild && globalThis.Evidence.mount(el, {...bank, depth: 3, selected: 'tx-0'})} />
</>;
const save = <><span>분개 15건 저장</span><button className="send">저장</button><button className="text">취소</button></>;
export const Ipad = {name: 'iPad · 뷰포트 · 장부 640 · 증빙 들어옴', parameters: {skin: ['shell', 'workbench', 'theme']}, args: {targetWidth: 640, control: ledger, turn: save}};
export const IpadRecords = {name: 'iPad 세로 834 · 기록 페이지', args: {width: 834, records: f.records}};
