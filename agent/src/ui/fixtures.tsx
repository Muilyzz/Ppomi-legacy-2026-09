// 스토리에 꽂는 가짜 서브트리. 실제 App(main.tsx)이 주입하는 것과 같은 모양의 DOM을 만든다.
import React from "react";
import { Shell, Pane, Log, Welcome, Bubble, BubbleActions, Thinking, ToolCard, Procedure, Waiting, Composer, CallCard, CallBar, IncomingCall } from "./shell";
import { StepRecordPane } from "./step-record-pane";
import { ControlHeader, RecordsHeader } from "./workbench";

export const tools = <>
  <ToolCard name="app_open" label="앱 열기 · DOM" state="output-available" input={{ target: "토스" }} output={{ opened: "viva.republica.toss" }} />
  <ToolCard name="screen_read" label="화면 읽기 · DOM" state="output-available" output="잔액 526,852원" />
  <ToolCard name="ui_tap" label="화면 누르기 · DOM" state="input-available" input={{ target: "송금" }} />
</>;
export const failedTools = <>
  <ToolCard name="app_open" label="앱 열기 · DOM" state="output-available" output={{ opened: "viva.republica.toss" }} />
  <ToolCard name="screen_read" label="화면 읽기 · DOM" state="output-error" errorText="화면 확인 필요" defaultOpen />
</>;

export const welcome = (android = false) => <Welcome hint={android ? "앱 열기 · 화면 읽기 · 일 처리" : "절차 · 기억 · 할 일"}
  suggestions={[android ? "토스를 열고 현재 화면을 읽어 줘." : "사용할 수 있는 플레이북을 찾아서 알려 줘."]} onSuggest={() => {}} />;

export const messages = <>
  <Bubble role="user" text="토스 열고 잔액 읽어 줘" />
  <Thinking text="토스 앱을 열고 홈 화면의 잔액을 읽으면 된다. 이체 화면은 열지 않는다." streaming={false} />
  <Bubble role="assistant" text="토스를 열었습니다. 잔액 **526,852원**." actions={<BubbleActions text="토스를 열었습니다. 잔액 526,852원." onRetry={() => {}} />} />
  <Bubble role="user" text="이번 달 지출도" />
  <Bubble role="assistant" text="생각 중…" pending />
</>;
export const procedure = <Procedure title="KB 인증센터에서 사업자 공동인증서 발급·재발급" defaultOpen
  steps={[{ id: "open", title: "KB 기업 인증센터 진입" }, { id: "form", title: "사업자번호·ID 확인" }, { id: "account", title: "계좌번호 입력" }, { id: "issue", title: "본인 인증·발급" }]}
  outcomes={{ open: "ok", form: "ok", account: "fail" }} />;
export const waiting = <Waiting items={["끝나면 영수증도 저장해 줘", "결과를 톡으로 알려 줘"]} onRemove={() => {}} />;

/** 통화 중: 시작 카드 뒤에 말풍선(전사)이 쌓인다. */
export const callInProgress = <>
  <CallCard kind="start" time="10:21" />
  <Bubble role="user" text="이번 달 카드값 얼마야" />
  <Bubble role="assistant" text="이번 달 신한카드 62,000원입니다. 납부일은 25일이에요." />
</>;
export const callEnded = <>
  <CallCard kind="start" time="10:21" />
  <Bubble role="user" text="이번 달 카드값 얼마야" />
  <Bubble role="assistant" text="이번 달 신한카드 62,000원입니다. 납부일은 25일이에요." />
  <CallCard kind="end" time="10:24" />
</>;

export const composer = (disabled = false, waiting = false) =>
  <Composer status={waiting ? "streaming" : "ready"} disabled={disabled} onSend={async () => {}} onStop={() => {}} onCall={() => {}} />;
export const callBar = (word = "듣는 중") => <CallBar word={word} onEnd={() => {}} />;
export const incoming = <IncomingCall reason="62,000원 결제 승인" onAccept={() => {}} onLater={() => {}} />;

/** 작업대 스토리의 대화. 넓을 때 오른쪽, 좁을 때 기본 화면 전체를 쓴다. */
export const conversation = <Shell conversation={
  <Pane log={<Log>{messages}</Log>} composer={composer()} />} />;

export const topBar = <><strong>뽀미</strong><button className="text" aria-label="내 계정">나</button></>;

export const controlHeader = <ControlHeader
  target={<span>iPhone</span>} />;

export const turn = <div className="turn-actions" role="group" aria-label="사람 차례"><span>62,000원 결제</span><button className="send">승인</button><button className="text">취소</button></div>;

export const recordTabs = ["타임라인", "증빙", "분개", "절차", "건강", "3D"];
export const records = <>
  <RecordsHeader>
    <div role="tablist" aria-label="기록 종류">
      {recordTabs.map((tab, i) => <button key={tab} role="tab" aria-selected={i === 0}>{tab}</button>)}
    </div>
  </RecordsHeader>
  <div className="records-body"><StepRecordPane /></div>
</>;
