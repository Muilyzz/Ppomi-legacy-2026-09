// 대화 셸의 뼈대: AI Elements(shadcn + Tailwind) 위에 뽀미 토큰을 입힌다(index.css 가 Tailwind 색 이름을 토큰에 매핑).
// 상태·브리지는 App(main.tsx)이 갖고, 여기는 DOM 모양뿐이다. 스토리북은 같은 뼈대에 가짜 서브트리를 꽂아 본다.
// 대화는 하나다. 음성은 그 안의 통화 한 토막이다(전화처럼 걸고 받고 끊는다). 요구 장부: docs/ui-tree.md.
import { useEffect, useState, type ReactNode } from "react";
import type { ChatStatus } from "ai";
import { CheckIcon, CircleIcon, CopyIcon, CornerDownLeftIcon, PhoneIcon, PhoneOffIcon, RefreshCwIcon, SquareIcon, XCircleIcon, XIcon } from "lucide-react";
import { Conversation, ConversationContent, ConversationEmptyState, ConversationScrollButton } from "@/components/ai-elements/conversation";
import { Message, MessageAction, MessageActions, MessageContent, MessageResponse } from "@/components/ai-elements/message";
import { Reasoning, ReasoningContent, ReasoningTrigger } from "@/components/ai-elements/reasoning";
import { Task, TaskContent, TaskItem, TaskTrigger } from "@/components/ai-elements/task";
import { Queue, QueueItem, QueueItemAction, QueueItemActions, QueueItemContent, QueueItemIndicator, QueueList, QueueSection, QueueSectionContent,
  QueueSectionLabel, QueueSectionTrigger } from "@/components/ai-elements/queue";
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
  return <Conversation className="min-h-0 flex-1" aria-label="현재 대화" aria-live="polite">
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

/** 말풍선. 비서 글은 마크다운(스트리밍 대응), 내 글은 그대로. pending 은 답을 기다리는 임시 한 줄. actions 는 말풍선 아래 작은 버튼들. */
export function Bubble({ role, text, pending, actions }: { role: "user" | "assistant"; text: string; pending?: boolean; actions?: ReactNode }) {
  return <Message from={role} role="article" aria-label={role === "user" ? "나" : "뽀미"}>
    <MessageContent className={cn("text-sm leading-7", pending && "animate-pulse text-muted-foreground")}>
      {role === "assistant" ? <MessageResponse>{text || "…"}</MessageResponse> : <p className="m-0 whitespace-pre-wrap break-words">{text}</p>}
    </MessageContent>
    {actions}
  </Message>;
}

/** 비서 말풍선의 동작: 복사, 마지막 답이면 다시 답하기. */
export function BubbleActions({ text, onRetry }: { text: string; onRetry?: () => void }) {
  return <MessageActions className="-mt-1">
    <MessageAction tooltip="복사" label="복사" onClick={() => { void navigator.clipboard?.writeText(text); }}><CopyIcon className="size-4" /></MessageAction>
    {onRetry && <MessageAction tooltip="다시 답하기" label="다시 답하기" onClick={onRetry}><RefreshCwIcon className="size-4" /></MessageAction>}
  </MessageActions>;
}

/** 모델의 추론 요약: 흐르는 동안 열리고 끝나면 접힌다. */
export function Thinking({ text, streaming }: { text: string; streaming: boolean }) {
  return <Reasoning isStreaming={streaming} className="max-w-[95%]">
    <ReasoningTrigger getThinkingMessage={(isStreaming, duration) => isStreaming || duration === 0
      ? <span className="animate-pulse">생각하는 중…</span>
      : <p>{duration === undefined ? "잠깐 생각함" : `${duration}초 생각함`}</p>} />
    <ReasoningContent>{text}</ReasoningContent>
  </Reasoning>;
}

export type ProcedureStep = { id: string; title: string };
export type StepOutcome = "ok" | "changed" | "fail";
/** 절차 카드: 플레이북 한 기능의 단계 목록. 판정(verify_step)이 붙은 단계는 완료·실패로 표시된다. */
export function Procedure({ title, steps, outcomes, defaultOpen }:
  { title: string; steps: ProcedureStep[]; outcomes: Record<string, StepOutcome>; defaultOpen?: boolean }) {
  const done = steps.filter(step => outcomes[step.id] && outcomes[step.id] !== "fail").length;
  return <Task defaultOpen={defaultOpen ?? false} className="max-w-[95%]">
    <TaskTrigger title={`${title} · ${done}/${steps.length}`} />
    <TaskContent>
      {steps.map(step => <TaskItem key={step.id} className="flex items-start gap-2">
        {outcomes[step.id] === "fail" ? <XCircleIcon className="mt-0.5 size-4 shrink-0 text-destructive" aria-label="실패" />
          : outcomes[step.id] ? <CheckIcon className="mt-0.5 size-4 shrink-0 text-accent-foreground" aria-label="완료" />
          : <CircleIcon className="mt-0.5 size-4 shrink-0 text-muted-foreground" aria-label="대기" />}
        <span className={cn(outcomes[step.id] && outcomes[step.id] !== "fail" && "text-muted-foreground")}>{step.title}</span>
      </TaskItem>)}
    </TaskContent>
  </Task>;
}

/** 대기열: 비서가 일하는 동안 보낸 글은 여기 줄을 서고, 차례가 오면 순서대로 나간다. */
export function Waiting({ items, onRemove }: { items: string[]; onRemove: (index: number) => void }) {
  if (!items.length) return null;
  return <Queue className="mb-2">
    <QueueSection defaultOpen>
      <QueueSectionTrigger><QueueSectionLabel label="건 대기" count={items.length} /></QueueSectionTrigger>
      <QueueSectionContent>
        <QueueList>
          {items.map((text, index) => <QueueItem key={`${index}-${text}`} className="group">
            <QueueItemIndicator />
            <QueueItemContent>{text}</QueueItemContent>
            <QueueItemActions><QueueItemAction aria-label="대기열에서 빼기" onClick={() => onRemove(index)}><XIcon className="size-4" /></QueueItemAction></QueueItemActions>
          </QueueItem>)}
        </QueueList>
      </QueueSectionContent>
    </QueueSection>
  </Queue>;
}

export type ToolCardProps = {
  name: string; label: string; state: ToolPart["state"];
  input?: unknown; output?: unknown; errorText?: string; defaultOpen?: boolean;
  /** 실행 중인 도구 안의 단계("OCR 읽는 중"): 네이티브 런타임 이벤트가 알린다. */
  progress?: string;
};
/** 도구 카드: 이름(관찰 방식 태그 포함)과 상태 배지. 펼치면 입력·결과. */
export function ToolCard({ name, label, state, input, output, errorText, defaultOpen, progress }: ToolCardProps) {
  const body = input !== undefined || output !== undefined || errorText;
  // A card that fails after it was mounted (state flips from running to error) still opens itself; the person can close it.
  const [open, setOpen] = useState(!!defaultOpen);
  useEffect(() => { if (defaultOpen) setOpen(true); }, [defaultOpen]);
  return <Tool className="mb-0 max-w-[95%] bg-card" open={open} onOpenChange={setOpen}>
    <ToolHeader type={`tool-${name}`} state={state} title={progress ? `${label} · ${progress}` : label} className="py-2.5" />
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
  return <PromptInput className="rounded-2xl [&>[data-slot=input-group]]:rounded-2xl [&>[data-slot=input-group]]:bg-card" aria-label="메시지 입력"
    onSubmit={async ({ text }) => {
      const value = (text ?? "").trim();
      if (!value) throw new Error("empty");
      await onSend(value);
    }}>
    <PromptInputBody>
      <PromptInputTextarea id="chat-input" aria-label="메시지" placeholder={placeholder} disabled={disabled} rows={2} maxLength={12_000}
        className="min-h-12 max-h-32 px-3.5 pt-3 text-sm placeholder:text-muted-foreground" />
    </PromptInputBody>
    <PromptInputFooter className="px-2 pb-2">
      <PromptInputTools>
        {onCall && <PromptInputButton tooltip="통화 걸기" aria-label="통화 걸기" disabled={disabled || callDisabled} onClick={onCall}>
          <PhoneIcon className="size-4" />
        </PromptInputButton>}
      </PromptInputTools>
      <PromptInputSubmit status={status} onStop={onStop} disabled={generating ? false : disabled || empty} size="sm"
        aria-label={generating ? "진행 정지" : "메시지 보내기"} className="gap-1.5 rounded-full px-3">
        {generating ? <><SquareIcon className="size-3.5" />정지</> : <><CornerDownLeftIcon className="size-4" />보내기</>}
      </PromptInputSubmit>
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
  return <div className="mb-2 flex flex-wrap items-center gap-3 rounded-xl border bg-card px-3.5 py-2.5 text-sm" role="alert" aria-label="걸려온 통화">
    <strong className="font-medium">뽀미가 부릅니다</strong>
    <span className="min-w-0 flex-1 break-words text-muted-foreground">{reason}</span>
    <Button size="sm" onClick={onAccept}>받기</Button>
    <Button size="sm" variant="ghost" onClick={onLater}>나중에</Button>
  </div>;
}
