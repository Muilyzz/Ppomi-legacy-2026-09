// Windows 셸의 계정 상태 셋: 로그인 전 · Mac 승인 대기 · 연결됨. 실제 ChatPanel·ExecutorPanel 에 오프라인 실행기(windows-executor.fixture)를 꽂는다.
// 브라우저·네트워크·토큰 없음. '승인 대기' 스토리의 "Mac 승인 시뮬레이션"은 소유자가 Mac 의 나 › 기기 승인에서 누르는 승인을 대신한다.
import React, {useState} from 'react';
import {createRoot} from 'react-dom/client';
import {ChatPanel} from '../agent/src/chat-panel';
import {ExecutorPanel} from '../agent/src/executor-panel';
import {createWindowsExecutorStory} from './windows-executor.fixture';
import '../agent/src/executor-panel.css';

function WindowsShell({state, simulateApproval}) {
  const [fixture] = useState(() => createWindowsExecutorStory(state));
  const [approved, setApproved] = useState(false);
  return <div className="windows-account-story" style={{height: '100dvh', display: 'grid', gridTemplateRows: simulateApproval ? 'auto minmax(0, 1fr)' : 'minmax(0, 1fr)'}}>
    {simulateApproval && <div style={{display: 'flex', gap: '.75rem', alignItems: 'center', padding: '.5rem .75rem', borderBottom: '1px solid var(--line)'}}>
      <span style={{opacity: .7}}>Mac 쪽 시뮬레이션</span>
      <button className="text" aria-label="Mac 승인 시뮬레이션" disabled={approved} onClick={() => { fixture.approve(); setApproved(true); }}>{approved ? '승인됨 · 다음 확인에서 연결' : '나 › 기기 승인 › 승인'}</button>
    </div>}
    <ChatPanel host={fixture.host} frame={(slots, render) => <ExecutorPanel {...slots} manage={fixture.manage}>{render}</ExecutorPanel>} />
  </div>;
}
const mount = (node) => {
  const el = document.createElement('div');
  createRoot(el).render(<><style>{'body:has(.workbench){max-width:none;padding:0}'}</style>{node}</>);
  return el;
};
// 시트는 버튼을 눌러야 열린다(Radix Dialog 는 body 에 포털). 부트스트랩이 도착해 버튼이 생길 때까지 잠깐 기다린다.
const open = async (label) => {
  for (let attempt = 0; attempt < 60; attempt++) {
    const button = document.querySelector(`button[aria-label="${label}"]`);
    if (button && !button.disabled) { button.click(); return; }
    await new Promise((resolve) => setTimeout(resolve, 50));
  }
};

export default {
  title: 'Windows 계정',
  id: 'windows-account',
  parameters: {skin: ['shell', 'workbench']},
  render: (args) => mount(<WindowsShell {...args} />),
  argTypes: {
    state: {control: 'radio', options: ['signed-out', 'pending-approval', 'connected'], description: '실행기가 보고하는 계정 상태'},
    simulateApproval: {control: 'boolean', description: 'Mac 승인 버튼(시뮬레이션) 표시'},
  },
  args: {state: 'signed-out', simulateApproval: false},
};

export const SignedOut = {name: '로그인 전', args: {state: 'signed-out'}};
export const SignedOutAccount = {name: '로그인 전 · 계정 시트', args: {state: 'signed-out'}, play: () => open('Google 계정으로 로그인')};
export const PendingApproval = {name: '승인 대기', args: {state: 'pending-approval', simulateApproval: true}};
export const PendingApprovalAccount = {name: '승인 대기 · 계정 시트', args: {state: 'pending-approval'}, play: () => open('나 · 계정')};
// 소유자가 Mac 에서 승인을 누른 뒤: 실행기의 다음 상태 확인이 approved 를 보고 → 패널이 bootstrap 을 다시 읽어 → 띠가 사라진다.
export const ApprovedOnMac = {name: '승인 대기 → Mac 승인 → 연결', args: {state: 'pending-approval', simulateApproval: true}, play: () => open('Mac 승인 시뮬레이션')};
export const Connected = {name: '연결됨', args: {state: 'connected'}};
export const ConnectedAccount = {name: '연결됨 · 계정 시트', args: {state: 'connected'}, play: () => open('나 · 계정')};
export const SettingsSheet = {name: '설정 · 제어할 앱만', args: {state: 'connected'}, play: () => open('설정')};
