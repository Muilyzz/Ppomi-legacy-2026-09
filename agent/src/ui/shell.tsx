// 대화 셸의 뼈대: AI Elements(shadcn + Tailwind) 위에 뽀미 토큰을 입힌다(index.css 가 Tailwind 색 이름을 토큰에 매핑).
// 상태·브리지는 App(main.tsx)이 갖고, 여기는 DOM 모양뿐이다. 스토리북은 같은 뼈대에 가짜 서브트리를 꽂아 본다.
// 대화는 하나다. 음성은 그 안의 통화 한 토막이다(전화처럼 걸고 받고 끊는다). 요구 장부: docs/ui-tree.md.
import type { ReactNode } from "react";
import type { ChatStatus } from "ai";
import { PhoneIcon, PhoneOffIcon } from "lucide-react";
import { Conversation, ConversationContent, ConversationEmptyState, ConversationScrollButton } from "@/components/ai-elements/conversation";
import { Message, MessageContent, MessageResponse } from "@/components/ai-elements/message";
import { Tool, ToolContent, ToolHeader, ToolInput, ToolOutput, type ToolPart } from "@/components/ai-elements/tool";
import { PromptInput, PromptInputBody, PromptInputButton, PromptInputFooter, PromptInputProvider, PromptInputSubmit, PromptInputTextarea,
  PromptInputTools, usePromptInputController } from "@/components/ai-elements/prompt-input";
import { Suggestion } from "@/components/ai-elements/suggestion";
import { Button } from "@/components/ui/button";
import { TooltipProvider } from "@/components/ui/tooltip";
import { cn } from "@/lib/utils";

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

/** section.conversation: 수신 띠 / 로그 / 입력(또는 통화 바). 도구 카드는 로그 안에 시간순으로 놓인다. */
export function Pane({ incoming, log, composer }: { incoming?: ReactNode; log: ReactNode; composer: ReactNode }) {
  return <section className="conversation" aria-label="뽀미 대화">
    {incoming}{log}{composer}
  </section>;
}

/** 로그(role=log): 글·통화 말풍선·도구 카드·질문 카드가 시간순으로 쌓인다. 바닥 고정 스크롤은 AI Elements(use-stick-to-bottom)가 맡는다. */
export function Log({ children }: { children?: ReactNode }) {
  return <Conversation className="min-h-0 flex-1" aria-label="현재 대화">
    <ConversationContent className="gap-4 px-0.5 py-3">{children}</ConversationContent>
    <ConversationScrollButton aria-label="맨 아래로" />
  </Conversation>;
}

/** 첫 화면: 한 줄 힌트와 제안 칩. 칩을 누르면 그 문장을 바로 보낸다. */
export function Welcome({ hint, suggestions, disabled, onSuggest }:
  { hint: ReactNode; suggestions: string[]; disabled?: boolean; onSuggest: (text: string) => void }) {
  return <ConversationEmptyState className="gap-4 py-6">
    <p className="text-muted-foreground text-sm">{hint}</p>
    <div className="flex flex-wrap justify-center gap-2">
      {suggestions.map(text => <Suggestion key={text} suggestion={text} disabled={disabled} onClick={onSuggest} />)}
    </div>
  </ConversationEmptyState>;
}

/** 말풍선. 비서 글은 마크다운(스트리밍 대응), 내 글은 그대로. pending 은 답을 기다리는 임시 한 줄. */
export function Bubble({ role, text, pending }: { role: "user" | "assistant"; text: string; pending?: boolean }) {
  return <Message from={role} aria-label={role === "user" ? "나" : "뽀미"}>
    <MessageContent className={cn("text-sm leading-7", pending && "animate-pulse text-muted-foreground")}>
      {role === "assistant" ? <MessageResponse>{text || "…"}</MessageResponse> : <p className="m-0 whitespace-pre-wrap break-words">{text}</p>}
    </MessageContent>
  </Message>;
}

export type ToolCardProps = {
  name: string; label: string; state: ToolPart["state"];
  input?: unknown; output?: unknown; errorText?: string; defaultOpen?: boolean;
};
/** 도구 카드: 이름(관찰 방식 태그 포함)과 상태 배지. 펼치면 입력·결과. */
export function ToolCard({ name, label, state, input, output, errorText, defaultOpen }: ToolCardProps) {
  const body = input !== undefined || output !== undefined || errorText;
  return <Tool className="mb-0 max-w-[95%] bg-card" defaultOpen={defaultOpen}>
    <ToolHeader type={`tool-${name}`} state={state} title={label} className="py-2.5" />
    {body && <ToolContent>
      {input !== undefined && <ToolInput input={input} />}
      <ToolOutput output={output} errorText={errorText} />
    </ToolContent>}
  </Tool>;
}

export type ComposerProps = {
  status: ChatStatus; disabled?: boolean; placeholder?: string;
  onSend: (text: string) => Promise<void>; onStop: () => void; onCall?: () => void; callDisabled?: boolean;
};
/** 입력창(AI Elements PromptInput). Enter 전송(한글 조합 중 제외)·Shift+Enter 줄바꿈·자동 높이. 보내기 실패는 거부로 알려 글을 남긴다. */
export function Composer(props: ComposerProps) {
  return <TooltipProvider><PromptInputProvider><ComposerForm {...props} /></PromptInputProvider></TooltipProvider>;
}
function ComposerForm({ status, disabled, placeholder = "할 일", onSend, onStop, onCall, callDisabled }: ComposerProps) {
  const controller = usePromptInputController();
  const generating = status === "submitted" || status === "streaming";
  const empty = !controller.textInput.value.trim();
  return <PromptInput className="rounded-2xl border bg-card shadow-none" aria-label="메시지 입력"
    onSubmit={async ({ text }) => {
      const value = (text ?? "").trim();
      if (!value) throw new Error("empty");
      await onSend(value);
    }}>
    <PromptInputBody>
      <PromptInputTextarea id="chat-input" aria-label="메시지" placeholder={placeholder} disabled={disabled} rows={2}
        className="min-h-12 max-h-32 px-3.5 pt-3 text-sm placeholder:text-muted-foreground" />
    </PromptInputBody>
    <PromptInputFooter className="px-2 pb-2">
      <PromptInputTools>
        {onCall && <PromptInputButton tooltip="통화 걸기" aria-label="통화 걸기" disabled={disabled || callDisabled} onClick={onCall}>
          <PhoneIcon className="size-4" />
        </PromptInputButton>}
      </PromptInputTools>
      <PromptInputSubmit status={status} onStop={onStop} disabled={generating ? false : disabled || empty}
        aria-label={generating ? "진행 정지" : "메시지 보내기"} className="rounded-full" />
    </PromptInputFooter>
  </PromptInput>;
}

/** 통화의 시작·끝을 로그에 남기는 카드. */
export function CallCard({ kind, time }: { kind: "start" | "end"; time: string }) {
  return <div className="mx-auto flex w-fit items-center gap-2 rounded-full border px-3.5 py-1 text-muted-foreground text-xs tabular-nums"
    aria-label={kind === "start" ? "통화 시작" : "통화 끝"}>
    {kind === "start" ? "통화 시작" : "통화 끝"} · {time}
  </div>;
}

/** 통화 중 입력창 자리: 상태 한 마디(연결 중·듣는 중·말하는 중·진행 중) + 끊기. */
export function CallBar({ word, onEnd }: { word: ReactNode; onEnd: () => void }) {
  return <div className="flex items-center justify-between rounded-2xl border bg-card py-2.5 pr-2.5 pl-5">
    <span role="status" className="text-muted-foreground text-sm">{word}</span>
    <Button variant="destructive" size="sm" onClick={onEnd} aria-label="통화 끊기"><PhoneOffIcon className="size-4" />끊기</Button>
  </div>;
}

/** 걸려온 통화: 뽀미가 사람 차례(승인·질문)나 예약된 일로 부른다. 받기 = 통화 시작(뽀미가 용건을 말한다), 나중에 = 띠를 내린다. */
export function IncomingCall({ reason, onAccept, onLater }: { reason: ReactNode; onAccept: () => void; onLater: () => void }) {
  return <div className="mb-2 flex items-center gap-3 rounded-xl border bg-card px-3.5 py-2.5 text-sm" role="alert" aria-label="걸려온 통화">
    <strong className="font-medium">뽀미가 부릅니다</strong>
    <span className="min-w-0 flex-1 break-words text-muted-foreground">{reason}</span>
    <Button size="sm" onClick={onAccept}>받기</Button>
    <Button size="sm" variant="ghost" onClick={onLater}>나중에</Button>
  </div>;
}
