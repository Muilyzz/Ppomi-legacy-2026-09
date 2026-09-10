// 대화 셸의 뼈대. 각 부분은 평범한 DOM 하나에 서브트리를 주입받는다(DI처럼). 상태·브리지·스타일은 여기 없다:
// 상태는 App이, 스타일은 루트가 주입한다(tokens.css + style.css). 스토리북은 같은 뼈대에 가짜 서브트리를 꽂아 본다.
// 대화는 하나다. 음성은 그 안의 통화 한 토막이다(전화처럼 걸고 받고 끊는다). 요구 장부: docs/ui-tree.md.
import type { ReactNode, Ref } from "react";

export type ShellProps = { platform?: string; error?: ReactNode; conversation: ReactNode };
/** main.agent-shell: 한 열. 오류 띠 위, 대화 아래. */
export function Shell(p: ShellProps) {
  return <main className={"agent-shell" + (p.platform ? " " + p.platform : "")}>
    {p.error}{p.conversation}
  </main>;
}

export function ErrorBanner({ children, onClose }: { children: ReactNode; onClose?: () => void }) {
  return <div className="error" role="alert">{children}{onClose && <button aria-label="알림 닫기" onClick={onClose}>×</button>}</div>;
}

/** section.conversation: 수신 띠 / 도구 / 로그 / 입력(또는 통화 바). */
export function Conversation({ incoming, tools, log, composer }:
  { incoming?: ReactNode; tools?: ReactNode; log: ReactNode; composer: ReactNode }) {
  return <section className="conversation" aria-label="뽀미 대화">
    {incoming}{tools}{log}{composer}
  </section>;
}

/** 걸려온 통화: 뽀미가 사람 차례(승인·질문)나 예약된 일로 부른다. 받기 = 통화 시작(뽀미가 용건을 말한다), 나중에 = 띠를 내린다. */
export function IncomingCall({ reason, onAccept, onLater }: { reason: ReactNode; onAccept: () => void; onLater: () => void }) {
  return <div className="incoming" role="alert" aria-label="걸려온 통화">
    <strong>뽀미가 부릅니다</strong>
    <span className="reason">{reason}</span>
    <button className="send" onClick={onAccept}>받기</button>
    <button className="text" onClick={onLater}>나중에</button>
  </div>;
}

export type ToolRow = { id: string; status: "running" | "success" | "error"; label: string; detail: string };
export function ToolSummary({ summary, rows }: { summary: ReactNode; rows: ToolRow[] }) {
  return <details className="tool-summary">
    <summary>{summary}</summary>
    <ol className="tool-progress" aria-label="도구 실행 상태">
      {rows.map((row) => <li key={row.id} className={row.status}>
        <span aria-hidden="true">{row.status === "running" ? "◌" : row.status === "success" ? "✓" : "!"}</span>
        <span>{row.label}</span>
        <small>{row.detail}</small>
      </li>)}
    </ol>
  </details>;
}

/** 로그 하나(role=log). 글·통화 말풍선·통화 카드·질문 카드가 시간순으로 쌓인다. 스크롤 위치는 App이 ref로 다룬다. */
export function ChatLog({ logRef, children }: { logRef?: Ref<HTMLDivElement>; children?: ReactNode }) {
  return <div className="chat-log" ref={logRef} role="log" aria-label="현재 대화" aria-live="polite">{children}</div>;
}

export function Welcome({ hint, suggestion, disabled, onSuggest }:
  { hint: ReactNode; suggestion: ReactNode; disabled?: boolean; onSuggest: () => void }) {
  return <div className="chat-welcome">
    <p>{hint}</p>
    <button className="suggestion" disabled={disabled} onClick={onSuggest}>{suggestion}</button>
  </div>;
}

export function Message({ role, text }: { role: "user" | "assistant"; text: string }) {
  return <article className={"message " + role} aria-label={role === "user" ? "나" : "뽀미"}>
    <p>{text || "…"}</p>
  </article>;
}

/** 통화의 시작·끝을 로그에 남기는 카드. */
export function CallCard({ kind, time }: { kind: "start" | "end"; time: string }) {
  return <article className={"call " + kind} aria-label={kind === "start" ? "통화 시작" : "통화 끝"}>
    {kind === "start" ? "통화 시작" : "통화 끝"} · {time}
  </article>;
}

/** 입력창. 📞로 통화를 걸고, onStop이 있으면 보내기가 정지로 바뀐다(진행 중 사람이 세우는 유일한 수단). */
export function Composer({ value, disabled, canSend, onChange, onSend, onStop, onCall, callDisabled }:
  { value: string; disabled?: boolean; canSend: boolean; onChange: (value: string) => void; onSend: () => void;
    onStop?: () => void; onCall?: () => void; callDisabled?: boolean }) {
  return <form className="composer" onSubmit={(event) => { event.preventDefault(); onSend(); }}>
    {onCall && <button className="call-button" type="button" aria-label="통화 걸기" disabled={disabled || callDisabled} onClick={onCall}>📞</button>}
    <textarea id="chat-input" aria-label="메시지" placeholder="할 일" rows={2} maxLength={8000}
      value={value} disabled={disabled} autoComplete="off" spellCheck={false}
      onChange={(event) => onChange(event.target.value)}
      onKeyDown={(event) => {
        if (event.key === "Enter" && !event.shiftKey && !event.nativeEvent.isComposing) { event.preventDefault(); onSend(); }
      }} />
    {onStop
      ? <button className="send" type="button" aria-label="진행 정지" onClick={onStop}>정지</button>
      : <button className="send" type="submit" aria-label="메시지 보내기" disabled={!canSend}>보내기</button>}
  </form>;
}

/** 통화 중 입력창 자리: 상태 한 마디(연결 중·듣는 중·말하는 중·진행 중) + 끊기. */
export function CallBar({ word, onEnd }: { word: ReactNode; onEnd: () => void }) {
  return <div className="composer call-bar">
    <span role="status">{word}</span>
    <button className="send" type="button" aria-label="통화 끊기" onClick={onEnd}>끊기</button>
  </div>;
}
