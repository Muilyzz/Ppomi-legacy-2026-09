// 상단 · 대화 · 콘텐츠. 넓을 때 콘텐츠 왼쪽/대화 오른쪽, 좁을 때 대화와 요청한 콘텐츠 시트.
import React, {useState} from 'react';
import {createRoot} from 'react-dom/client';
import {Workbench, ControlSlot, ControlHeader, RecordsHeader} from '../agent/src/ui/workbench';
import {ChatPanel} from '../agent/src/chat-panel';
import {createStoryChatHost} from './chat-host.fixture';
import * as f from '../agent/src/ui/fixtures';
import '../Ppomi/Sources/Ppomi/Web/evidence.js';
import {bank} from './screens.js';

const control = (turn = false) => <>{f.controlHeader}<ControlSlot turn={turn}>{turn ? '승인 차례' : 'iPhone · 연결 끊김'}</ControlSlot>{turn && f.turn}</>;
const CLOSED = 400, OPEN = 704;
const frame = (width, node) => <div style={{width, height: '100dvh', flex: 'none'}}>{node}</div>;
const mount = (node) => {
  const el = document.createElement('div');
  // 낱장 기록의 theme.css는 body를 40rem로 제한한다. 작업대 스토리는 전체 폭을 쓴다.
  createRoot(el).render(<><style>{'body:has(.workbench){max-width:none;padding:0}'}</style>{node}</>);
  return el;
};

export default {
  title: '작업대',
  parameters: {skin: ['shell', 'workbench']},
  render: ({width, ...args}) => mount(width ? frame(width, <Workbench {...args} />) : <Workbench {...args} />),
  argTypes: {
    width: {control: 'number', description: '작업대 폭(px) · 비우면 뷰포트'},
    topBar: {table: {disable: true}}, conversation: {table: {disable: true}}, contentPane: {table: {disable: true}},
  },
  args: {topBar: f.topBar, conversation: f.conversation, contentPane: f.records},
};

export const Records = {name: '기본 · 콘텐츠 왼쪽 · 대화 오른쪽'};
export const Control = {name: '콘텐츠 · 제어', args: {contentPane: control(), contentLabel: '기기 제어'}};
export const Turn = {name: '콘텐츠 · 승인', args: {contentPane: control(true), contentLabel: '기기 제어'}};
export const Closed = {name: '접힘 · 400 · 대화만', args: {width: CLOSED}};
export const ClosedTurn = {name: '접힘 · 400 · 기록 열면 승인', args: {width: CLOSED, contentPane: control(true), contentLabel: '기기 제어'}};
export const Open = {name: '펼침 · 704 · 콘텐츠와 대화', args: {width: OPEN}};
export const SideBySide = {name: '나란히 · 400 | 704', render: (args) => mount(
  <div style={{display: 'flex', gap: '1rem', alignItems: 'flex-start'}}>
    {frame(CLOSED, <Workbench {...args} />)}{frame(OPEN, <Workbench {...args} />)}
  </div>
)};

// 실제 공유 증빙 렌더러도 콘텐츠 영역 안에서 스크롤한다.
const ledger = <>
  <RecordsHeader>
    <div role="tablist" aria-label="기록 종류">{f.recordTabs.map((tab, i) => <button key={tab} role="tab" aria-selected={i === 1}>{tab}</button>)}</div>
  </RecordsHeader>
  <div className="records-body" ref={(el) => el && !el.firstChild && globalThis.Evidence.mount(el, {...bank, depth: 3, selected: 'tx-0'})} />
</>;
export const Ipad = {name: 'iPad · 대화와 증빙', parameters: {skin: ['theme', 'shell', 'workbench']}, args: {contentPane: ledger}};
export const IpadRecords = {name: 'iPad 세로 · 834 · 대화와 증빙', parameters: {skin: ['theme', 'shell', 'workbench']}, args: {width: 834, contentPane: ledger}};

// 입력 중인 글을 둔 채 기록↔제어를 바꿔 대화가 유지되는지 직접 확인한다.
function SwitchingWorkbench({renderWorkbench = slots => <Workbench {...slots} />, ...args}) {
  const [controlling, setControlling] = useState(false);
  const toggle = <button className="text" onClick={() => setControlling(!controlling)}>{controlling ? '기록 보기' : '제어 보기'}</button>;
  const contentPane = controlling
    ? <><ControlHeader target="iPhone" actions={toggle} /><ControlSlot>iPhone · 연결 끊김</ControlSlot></>
    : <><RecordsHeader>{toggle}</RecordsHeader>{f.records}</>;
  return renderWorkbench({...args, contentPane, contentLabel: controlling ? '기기 제어' : '기록'});
}
export const SwitchContentPane = {name: '전환 · 대화 유지', render: ({width, ...args}) => mount(
  width ? frame(width, <SwitchingWorkbench {...args} />) : <SwitchingWorkbench {...args} />
)};

// 실제 대화 컴포넌트와 컨트롤러를 쓴다. 모델 응답만 메모리 안의 고정 예시이며 외부로 보내지 않는다.
function LiveChatWorkbench(args) {
  const [host] = useState(createStoryChatHost);
  const {conversation, ...slots} = args;
  return <ChatPanel host={host} frame={(_state, render) => <SwitchingWorkbench {...slots} renderWorkbench={render} />} />;
}
export const LiveChat = {name: '공통 채팅 · 오프라인 동작', render: ({width, ...args}) => mount(
  width ? frame(width, <LiveChatWorkbench {...args} />) : <LiveChatWorkbench {...args} />
)};

// 스토리 자체를 다시 마운트하지 않고 폭을 바꾼다. 실제 대화·초안·콘텐츠 시트의 수명을 함께 검토한다.
function ResizableLiveChat(args) {
  const [width, setWidth] = useState(OPEN);
  return <div className="workbench-size-story" style={{display: 'grid', gridTemplateRows: 'auto minmax(0, 1fr)', height: '100dvh'}}>
    <style>{'.workbench-size-story .workbench{height:100%}'}</style>
    <label style={{display: 'flex', alignItems: 'center', gap: '.75rem', padding: '.5rem'}}>
      작업대 폭
      <input aria-label="작업대 폭" type="range" min="360" max="1100" value={width} onChange={event => setWidth(Number(event.target.value))} />
      <output>{width}px</output>
    </label>
    <div style={{width, maxWidth: '100%', minHeight: 0}}><LiveChatWorkbench {...args} /></div>
  </div>;
}
export const LiveChatResize = {name: '공통 채팅 · 접기와 펼치기', render: ({width, ...args}) => mount(<ResizableLiveChat {...args} />)};
