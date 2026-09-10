// 스토리에 꽂는 가짜 서브트리. 실제 App(main.tsx)이 주입하는 것과 같은 모양의 DOM을 만든다.
import React from "react";
import { Shell, Conversation, ToolSummary, ChatLog, Welcome, Message, Composer, CallCard, CallBar, IncomingCall, type ToolRow } from "./shell";
import { ControlHeader, RecordsHeader } from "./workbench";

export const toolRows: ToolRow[] = [
  { id: "1", status: "success", label: "앱 열기", detail: "완료" },
  { id: "2", status: "success", label: "화면 읽기", detail: "완료" },
  { id: "3", status: "running", label: "화면 누르기", detail: "실행 중" },
];
export const tools = <ToolSummary summary="실행 중 · 3개" rows={toolRows} />;
export const failedTools = <ToolSummary summary="실행 내역 · 2개 · 실패"
  rows={[{ id: "1", status: "success", label: "앱 열기", detail: "완료" }, { id: "2", status: "error", label: "화면 읽기", detail: "실패 · 화면 확인 필요" }]} />;

export const welcome = (android = false) => <Welcome hint={android ? "앱 열기 · 화면 읽기 · 일 처리" : "절차 · 기억 · 할 일"}
  suggestion={android ? "토스 화면 읽기 ↗" : "플레이북 찾기 ↗"} onSuggest={() => {}} />;

export const messages = <>
  <Message role="user" text="토스 열고 잔액 읽어 줘" />
  <Message role="assistant" text="토스를 열었습니다. 잔액 526,852원." />
  <Message role="user" text="이번 달 지출도" />
  <Message role="assistant" text="" />
</>;

/** 통화 중: 시작 카드 뒤에 말풍선(전사)이 쌓인다. */
export const callInProgress = <>
  <CallCard kind="start" time="10:21" />
  <Message role="user" text="이번 달 카드값 얼마야" />
  <Message role="assistant" text="이번 달 신한카드 62,000원입니다. 납부일은 25일이에요." />
</>;
export const callEnded = <>
  <CallCard kind="start" time="10:21" />
  <Message role="user" text="이번 달 카드값 얼마야" />
  <Message role="assistant" text="이번 달 신한카드 62,000원입니다. 납부일은 25일이에요." />
  <CallCard kind="end" time="10:24" />
</>;

export const composer = (draft = "", disabled = false, waiting = false) =>
  <Composer value={draft} disabled={disabled} canSend={!disabled && draft.trim().length > 0} onChange={() => {}} onSend={() => {}}
    onStop={waiting ? () => {} : undefined} onCall={() => {}} />;
export const callBar = (word = "듣는 중") => <CallBar word={word} onEnd={() => {}} />;
export const incoming = <IncomingCall reason="62,000원 결제 승인" onAccept={() => {}} onLater={() => {}} />;

/* 작업대 */
export const conversation = <Shell conversation={
  <Conversation log={<ChatLog>{messages}</ChatLog>} composer={composer()} />} />;

export const controlHeader = <ControlHeader
  target={<select aria-label="대상"><option>iPhone</option><option>Android</option><option>Windows</option></select>}
  actions={<button className="text">기록</button>} />;

export const turn = <><span>62,000원 결제</span><button className="send">승인</button><button className="text">취소</button></>;

export const recordTabs = ["타임라인", "증빙", "분개", "절차", "건강", "3D"];
export const records = <>
  <RecordsHeader onBack={() => {}}>
    <div role="tablist" aria-label="기록 종류">
      {recordTabs.map((tab, i) => <button key={tab} role="tab" aria-selected={i === 0}>{tab}</button>)}
    </div>
  </RecordsHeader>
  <div className="records-body">비어 있음</div>
</>;
