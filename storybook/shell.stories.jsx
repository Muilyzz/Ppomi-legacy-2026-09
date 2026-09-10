// 대화 셸(Mac WKWebView·Android WebView가 공유하는 웹 UI). 대화 하나, 음성은 그 안의 통화. 뼈대(agent/src/ui/shell.tsx)에 가짜 서브트리를 꽂는다.
import React from 'react';
import {createRoot} from 'react-dom/client';
import {Shell, Conversation, ChatLog, ErrorBanner} from '../agent/src/ui/shell';
import * as f from '../agent/src/ui/fixtures';

export default {
  title: '대화 셸',
  parameters: {skin: ['shell']},
  render: (args) => { const el = document.createElement('div'); createRoot(el).render(<Shell {...args} />); return el; },
  argTypes: {
    platform: {control: 'radio', options: ['macos', 'android']},
    error: {table: {disable: true}}, conversation: {table: {disable: true}},
  },
  args: {platform: 'macos'},
};

export const First = {name: '처음', args: {
  conversation: <Conversation log={<ChatLog>{f.welcome()}</ChatLog>} composer={f.composer()} />,
}};
export const Talking = {name: '대화 중', args: {
  conversation: <Conversation tools={f.tools} log={<ChatLog>{f.messages}</ChatLog>} composer={f.composer('영수증도 저장', false, true)} />,
}};
export const Calling = {name: '통화 중', args: {
  conversation: <Conversation log={<ChatLog>{f.callInProgress}</ChatLog>} composer={f.callBar('듣는 중')} />,
}};
export const CallEnded = {name: '통화 끝', args: {
  conversation: <Conversation log={<ChatLog>{f.callEnded}</ChatLog>} composer={f.composer()} />,
}};
export const Incoming = {name: '걸려옴', args: {
  conversation: <Conversation incoming={f.incoming} log={<ChatLog>{f.messages}</ChatLog>} composer={f.composer()} />,
}};
export const Failed = {name: '오류', args: {
  error: <ErrorBanner onClose={() => {}}>채팅 연결 끊김</ErrorBanner>,
  conversation: <Conversation tools={f.failedTools} log={<ChatLog>{f.messages}</ChatLog>} composer={f.composer()} />,
}};
export const Unconfigured = {name: '미설정', args: {
  error: <ErrorBanner>설정에서 서버 주소</ErrorBanner>,
  conversation: <Conversation log={<ChatLog>{f.welcome()}</ChatLog>} composer={f.composer('', true)} />,
}};
export const AndroidOffline = {name: 'Android 미연결', args: {
  platform: 'android',
  error: <ErrorBanner>접근성 연결 필요 · 설정</ErrorBanner>,
  conversation: <Conversation log={<ChatLog>{f.welcome(true)}</ChatLog>} composer={f.composer()} />,
}};
