// Windows 셸의 계정 상태 셋: 로그인 전 · 연결됨(대화 가능) · 장부 키 대기. 실제 ChatPanel·ExecutorPanel 에 오프라인 실행기(windows-executor.fixture)를 꽂는다.
// 브라우저·네트워크·토큰 없음. Mac 기기 승인은 온보딩 관문이 아니다(MZZ-27).
import React, {useState} from 'react';
import {createRoot} from 'react-dom/client';
import {ChatPanel} from '../agent/src/chat-panel';
import {ExecutorPanel} from '../agent/src/executor-panel';
import {createWindowsExecutorStory} from './windows-executor.fixture';
import '../agent/src/executor-panel.css';

function WindowsShell({state, simulateKey}) {
  const [fixture] = useState(() => createWindowsExecutorStory(state));
  const [delivered, setDelivered] = useState(false);
  return <div className="windows-account-story" style={{height: '100dvh', display: 'grid', gridTemplateRows: simulateKey ? 'auto minmax(0, 1fr)' : 'minmax(0, 1fr)'}}>
    {simulateKey && <div style={{display: 'flex', gap: '.75rem', alignItems: 'center', padding: '.5rem .75rem', borderBottom: '1px solid var(--line)'}}>
      <span style={{opacity: .7}}>장부 키 전달(선택)</span>
      <button className="text" aria-label="장부 키 전달 시뮬레이션" disabled={delivered} onClick={() => { fixture.deliverRecordKey(); setDelivered(true); }}>{delivered ? '기록 키 도착' : '키를 가진 기기가 감쌈'}</button>
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
    state: {control: 'radio', options: ['signed-out', 'waiting-key', 'connected'], description: '실행기가 보고하는 계정 상태'},
    simulateKey: {control: 'boolean', description: '장부 키 전달 버튼(시뮬레이션) 표시'},
  },
  args: {state: 'signed-out', simulateKey: false},
};

export const SignedOut = {name: '로그인 전', args: {state: 'signed-out'}};
export const SignedOutAccount = {name: '로그인 전 · 계정 시트', args: {state: 'signed-out'}, play: () => open('Google 계정으로 로그인')};
export const WaitingKey = {name: '연결됨 · 장부 키 대기', args: {state: 'waiting-key'}};
export const WaitingKeyAccount = {name: '연결됨 · 장부 키 대기 · 계정 시트', args: {state: 'waiting-key'}, play: () => open('나 · 계정')};
export const KeyArrives = {name: '연결됨 → 장부 키 도착', args: {state: 'waiting-key', simulateKey: true}, play: () => open('장부 키 전달 시뮬레이션')};
export const Connected = {name: '연결됨', args: {state: 'connected'}};
export const ConnectedAccount = {name: '연결됨 · 계정 시트', args: {state: 'connected'}, play: () => open('나 · 계정')};
export const SettingsSheet = {name: '설정 · 제어할 앱만', args: {state: 'connected'}, play: () => open('설정')};
