import React, { Fragment, useEffect, useRef, useState, type ReactNode } from "react";
import { useChat, type UseChatHelpers } from "@ai-sdk/react";
import type { UIMessage } from "ai";
import { toolLabel } from "./tool-label";
import type { Bootstrap } from "./bridge";
import type { ChatHost } from "./chat-host";
import { VoiceController, type VoiceState, TextController, type TextState, type ChatMessage, type ToolProgress } from "./voice";
import { type InputCard } from "./questions";
import { QuestionCard } from "./question-cards";
import { Shell, ErrorBanner, Pane, Log, Welcome, Bubble, BubbleActions, Thinking, ToolCard, Procedure, Waiting, CallCard, Composer, CallBar, IncomingCall,
  type ProcedureStep, type StepOutcome, type ShellFrameSlots } from "./ui/shell";
import type { ToolPart } from "@/components/ai-elements/tool";
const toolFailureLabels: Record<string, string> = {
  accessibility_required: "접근성 연결 필요", app_not_allowed: "앱 허용 필요",
  app_not_found: "앱 없음", app_ambiguous: "앱 구분 필요", stale_screen: "화면 바뀜",
  no_active_screen: "화면 확인 필요", protected_action: "직접 처리",
  session_ended: "대화 종료", bridge_timeout: "시간 초과",
  playbook_not_found: "절차 없음", playbook_ambiguous: "절차 구분 필요",
  playbook_read_required: "절차 확인 필요", browser_environment_required: "Mac 브라우저 연결 필요",
  invalid_request: "요청 형식 오류", server_auth: "기기 인증 필요", server_rejected: "서버 거부",
  server_unavailable: "서버 응답 없음", response_invalid: "응답 형식 오류",
};
/* 통화 바의 한 마디. */
const callWords: Record<VoiceState, string> = { idle: "", connecting: "연결 중", listening: "듣는 중", speaking: "말하는 중", working: "진행 중" };
const clock = (at: number) => new Date(at).toLocaleTimeString("ko-KR", { hour: "2-digit", minute: "2-digit" });
type Call = { startedAt: number; endedAt?: number };
type Entry = { id: string; role?: "user" | "assistant"; node: ReactNode };
/** 도구는 실패해도 모델에 JSON 한 줄({ok:false, error:{code…}})을 돌려준다(bridge.formatNativeToolError). 카드에는 그 코드를 우리말로. */
function failureOf(output: unknown): { code: string; message: string } | null {
  if (typeof output !== "string" || !output.startsWith("{")) return null;
  try {
    const parsed = JSON.parse(output) as { ok?: unknown; error?: { code?: unknown; message?: unknown } };
    return parsed.ok === false && typeof parsed.error?.code === "string"
      ? { code: parsed.error.code, message: typeof parsed.error.message === "string" ? parsed.error.message : "" } : null;
  } catch { return null; }
}
/** RuntimeEvent.Kind / Method (Ppomi/Sources/Ppomi/Runtime/RuntimeEvent.swift) in Korean; unknown words show nothing. */
const progressWords: Record<string, string> = {
  started: "시작", reading: "읽는 중", read: "읽음", readFailed: "읽기 실패", acting: "조작 중", acted: "조작함",
  verifying: "확인 중", verified: "확인함", mismatch: "불일치", observing: "관찰 중", observed: "관찰함", cached: "캐시 사용",
  waitingForUser: "사용자 대기", userResponded: "응답 받음", handedOff: "넘김", returned: "끝", blocked: "차단", failed: "실패",
};
const progressMethods: Record<string, string> = { tool: "", ocr: "OCR", vlm: "VLM", replay: "재생", control: "화면 제어", storage: "저장", human: "사람", agent: "" };
const progressState = (status: ToolProgress["status"]): ToolPart["state"] =>
  status === "running" ? "input-available" : status === "success" ? "output-available" : "output-error";
const toolName = (tool: ToolPart) => tool.type === "dynamic-tool" ? tool.toolName : tool.type.slice(5);
const toolParts = (message: UIMessage): ToolPart[] =>
  message.parts.filter((part): part is ToolPart => part.type === "dynamic-tool" || part.type.startsWith("tool-"));
/** 도구 결과는 객체이거나 JSON 문자열이다. */
function objectOf(output: unknown): Record<string, unknown> | null {
  if (output && typeof output === "object") return output as Record<string, unknown>;
  if (typeof output === "string" && output.startsWith("{")) { try { return JSON.parse(output) as Record<string, unknown>; } catch { return null; } }
  return null;
}
/** read_playbook 결과의 기능별 단계 목록. */
function proceduresOf(output: unknown): { id: string; title: string; steps: ProcedureStep[] }[] {
  const playbook = objectOf(output)?.playbook as { capabilities?: { id?: unknown; title?: unknown; steps?: { id?: unknown; title?: unknown }[] }[] } | undefined;
  return (playbook?.capabilities ?? []).flatMap((capability) => typeof capability.id === "string" && typeof capability.title === "string"
    ? [{ id: capability.id, title: capability.title, steps: (capability.steps ?? []).flatMap((step) =>
        typeof step.id === "string" && typeof step.title === "string" ? [{ id: step.id, title: step.title }] : []) }] : []);
}

export type ChatFrameState = { boot?: Bootstrap; active: boolean; refresh(): Promise<void> };
export type ChatFrame = (state: ChatFrameState, render: (slots?: ShellFrameSlots) => ReactNode) => ReactNode;

/** 실제 글·통화 패널. 호스트와 프레임 어댑터는 마운트 동안 고정한다. */
export function ChatPanel({ host, frame }: { host: ChatHost; frame?: ChatFrame }) {
  const { bridge, readiness } = host;
  const [boot, setBoot] = useState<Bootstrap>();
  const [state, setState] = useState<VoiceState>("idle");
  const [error, setError] = useState("");
  const [textState, setTextState] = useState<TextState>("idle");
  const [messages, setMessages] = useState<ChatMessage[]>([]);   // 통화 대사(전사). 글 대화는 useChat 이 든다
  const [tools, setTools] = useState<ToolProgress[]>([]);
  const [inputCards, setInputCards] = useState<InputCard[]>([]);
  const [sending, setSending] = useState(false);
  const [settling, setSettling] = useState(false);
  const [call, setCall] = useState<Call | null>(null);
  const [incoming, setIncoming] = useState<string | null>(null);
  const [notices, setNotices] = useState<{ id: string; text: string; after: string | null }[]>([]);   // 비서의 톡(네이티브 사람 차례)
  const [queue, setQueue] = useState<string[]>([]);   // 비서가 일하는 동안 보낸 글. 차례가 오면 순서대로 나간다
  const [progress, setProgress] = useState<{ tool: string; text: string } | null>(null);   // 네이티브가 알리는 도구 내부 진행(OCR 읽는 중 …)
  const lastEntry = useRef<string | null>(null);   // a notice sits after the entry that was last when it arrived
  const missed = useRef<ReturnType<typeof setTimeout> | undefined>(undefined);   // 벨은 45초면 끊는다(부재중)
  const actionEpoch = useRef(0);
  const mounted = useRef(false);
  const connected = useRef(false);   // a call that never connected leaves no cards (the error banner says why)
  const inCallRef = useRef(false);   // rings during a call are dropped (the first-render closure below has no state)
  const bootRef = useRef<Bootstrap | undefined>(undefined);      // window hooks are installed once; they read the latest values through refs
  const answeredBootstrapCall = useRef<string | null>(null);
  const textStateRef = useRef<TextState>("idle");
  const chatRef = useRef<UseChatHelpers<UIMessage> | null>(null);   // the state callback below is created once; it clears the chat through this ref
  const textController = useRef<TextController | null>(null);
  const trackTools = (progress: ToolProgress) => setTools((old) => {
    const index = old.findIndex((item) => item.id === progress.id);
    return index < 0 ? [...old, progress].slice(-24) : old.map((item) => item.id === progress.id ? progress : item);
  });
  if (!textController.current) textController.current = new TextController(
    bridge,
    (next) => {
      setTextState(next); textStateRef.current = next;
      if (next === "connecting") { setCall(null); setNotices([]); }   // a new text conversation: the last call's cards and notices leave with its log
      if (next === "idle") {
        actionEpoch.current += 1;
        setTools([]); setSending(false); setSettling(true);
        chatRef.current?.setMessages([]);
        queueMicrotask(() => { void textController.current?.whenStopped().finally(() => setSettling(false)); });
      }
    },
    setError, trackTools, setInputCards,
  );
  // 글 대화: Vercel AI SDK useChat. 전송·상태(submitted/streaming/ready/error)·메시지 parts 는 SDK가, 도구 실행과 세션 수명은 TextController가 맡는다.
  const chat = useChat<UIMessage>({ transport: textController.current, onError: (error) => {
    if (textStateRef.current !== "idle") setError(error.message || "응답 실패");   // a session that already ended reports nothing
  } });
  chatRef.current = chat;
  const controller = useRef<VoiceController | null>(null);
  if (!controller.current)
    controller.current = new VoiceController(
      bridge,
      (next) => {
        setState(next);
        inCallRef.current = next !== "idle";
        if (next === "connecting") connected.current = false; else if (next !== "idle") connected.current = true;
        if (next === "idle") {
          setCall((current) => current && !current.endedAt ? (connected.current ? { ...current, endedAt: Date.now() } : null) : current);
          setTools([]); setSettling(true);
          queueMicrotask(() => { void controller.current?.whenStopped().finally(() => setSettling(false)); });
        }
      },
      setError, setInputCards, trackTools, setMessages,
    );
  const inCall = state !== "idle";
  const stopCurrent = async () => {
    actionEpoch.current += 1;
    setSending(false); setQueue([]);
    chat.stop();
    await textController.current?.stop();
    await controller.current?.stop();
  };
  /** 걸기(또는 받기): 글 대화가 열려 있으면 닫고 통화를 연다. 로그는 통화 카드부터 다시 쌓인다. refs만 읽어 훅에서도 안전하다. */
  const clearIncoming = () => { clearTimeout(missed.current); setIncoming(null); };
  const startCall = async (reason?: string) => {
    const epoch = actionEpoch.current;
    try {
      const b = await readiness.wait();
      if (!b.configured || b.voiceSupported === false || inCallRef.current || epoch !== actionEpoch.current) return;
      setError(""); clearIncoming();
      if (textStateRef.current !== "idle") await textController.current?.stop();
      const afterStop = actionEpoch.current;
      await controller.current?.whenStopped();
      if (inCallRef.current || afterStop !== actionEpoch.current) return;
      const current = await readiness.wait();
      if (!current.configured || inCallRef.current || afterStop !== actionEpoch.current) return;
      setMessages([]); setNotices([]); setCall({ startedAt: Date.now() });
      await controller.current?.start(current, reason);
    } catch (error) { setError(error instanceof Error ? error.message : "통화 연결 실패"); }
  };
  /** 나중에: 띠를 내리고 네이티브 벨(Android OS 통화)도 끊는다. */
  const declineCall = () => { clearIncoming(); void bridge.call("declineCall", {}).catch(() => {}); };
  const busy = chat.status === "submitted" || chat.status === "streaming";
  const waiting = sending || settling || textState === "connecting" || busy;
  /** 보내기. 바쁘면 대기열에 줄을 세우고, 실패는 거부로 알려 입력창이 글을 지우지 않게 한다. */
  const send = async (value: string) => {
    const text = value.trim();
    if (!text || text.length > 12_000 || inCall) throw new Error("busy");
    if (waiting) { setQueue((old) => [...old, text]); return; }
    const epoch = actionEpoch.current;
    setSending(true); setError("");
    try {
      const b = await readiness.wait();   // Native readiness acknowledgement must precede any sessionState call.
      if (epoch !== actionEpoch.current) throw new Error("stale");
      if (!b.configured) throw new Error("unconfigured");
      if (textStateRef.current === "idle") await textController.current?.start(b);
      if (epoch !== actionEpoch.current || textStateRef.current !== "ready") throw new Error("not ready");
      void chat.sendMessage({ text });   // resolves when the turn ends; status tracks it
    } finally { if (epoch === actionEpoch.current) setSending(false); }
  };
  // 대기열: 차례가 오면 맨 앞 글을 보낸다. 실패한 글은 버리고 배너가 이유를 말한다.
  useEffect(() => {
    if (!queue.length || waiting || inCall || boot?.configured === false) return;
    const [next, ...rest] = queue;
    setQueue(rest);
    void send(next).catch(() => {});
  }, [queue, waiting, inCall, boot?.configured]);
  const apply = (b: Bootstrap) => {
    try {
      const validated = readiness.prepare(b);
      clearTimeout(bootRetry.current);
      host.applyBootstrap(validated); bootRef.current = validated; setBoot(validated);
    } catch (error) {
      bootRef.current = undefined; setBoot(undefined);
      setError(error instanceof Error ? error.message : "앱 업데이트 필요");
      throw error;
    }
  };
  useEffect(() => {
    if (!boot) return; // Effects run after React committed the shell and validated bootstrap.
    void readiness.commit().then(() => {
      if (!mounted.current) return;
      if (boot.answerCall && answeredBootstrapCall.current !== boot.answerCall) {
        answeredBootstrapCall.current = boot.answerCall;
        void startCall(boot.answerCall);
      }
    }).catch((error) => {
      if (!mounted.current) return;
      clearTimeout(bootRetry.current);
      bootRef.current = undefined; setBoot(undefined); setQueue([]);
      setError(error instanceof Error ? error.message : "앱 업데이트 필요");
    });
  }, [boot]);
  // 입력은 즉시 가능하고 보내기만 준비를 기다린다. 해제된 패널의 늦은 응답은 재시도를 만들지 않는다.
  const bootRetry = useRef<ReturnType<typeof setTimeout> | undefined>(undefined);
  useEffect(() => {
    let active = true;
    mounted.current = true;
    const load = async (): Promise<void> => {
      try {
        const boot = await bridge.call<Bootstrap>("bootstrap");
        if (active) apply(boot);
      } catch (error) {
        if (!active) return;
        setError(readiness.failed && error instanceof Error ? error.message : "서버 연결 실패");
        if (!readiness.failed) bootRetry.current = setTimeout(() => { void load(); }, 5_000);
      }
    };
    void load();
    const unsubscribe = host.subscribe({
      refresh: () => {
        void bridge.call<Bootstrap>("bootstrap").then(boot => { if (active) apply(boot); }).catch(() => {});
      },
      answerCall: reason => { void startCall(typeof reason === "string" ? reason : undefined); },
      stop: () => { void stopCurrent(); },
      // 빈 용건은 해결됨. 통화 중이면 이미 말하고 있으니 수신 띠를 더 띄우지 않는다.
      incomingCall: reason => {
        if (inCallRef.current) return;
        clearTimeout(missed.current);
        const text = typeof reason === "string" && reason ? reason : null;
        setIncoming(text);
        if (text) missed.current = setTimeout(declineCall, 45_000);
      },
      toolProgress: event => {
        const tool = typeof event?.tool === "string" ? event.tool : "", kind = typeof event?.kind === "string" ? event.kind : "";
        const method = typeof event?.method === "string" ? progressMethods[event.method] ?? "" : "";
        if (!tool || !kind) return;
        const word = progressWords[kind];
        setProgress(word ? { tool, text: `${method}${method && word ? " " : ""}${word}`.trim() } : null);
      },
      notice: text => {
        if (typeof text === "string" && text) setNotices((old) => [...old, { id: crypto.randomUUID(), text, after: lastEntry.current }]);
      },
    });
    return () => {
      active = false;
      mounted.current = false;
      clearTimeout(bootRetry.current);
      clearTimeout(missed.current);
      unsubscribe();
      void stopCurrent();
    };
  }, []);
  // 벨소리: 걸려온 동안 두 음(440·480Hz)을 1초 울리고 2초 쉰다. 파일 없이 Web Audio. 30초 뒤엔 그친다(띠는 남는다).
  useEffect(() => {
    if (incoming === null || bootRef.current?.platform === "android") return;   // Android rings through the OS call UI
    const Ctx = window.AudioContext ?? (window as unknown as { webkitAudioContext?: typeof AudioContext }).webkitAudioContext;
    if (!Ctx) return;
    const ctx = new Ctx();
    let rings = 0;
    const ring = () => {
      if (rings++ >= 10) return;
      for (const hz of [440, 480]) {
        const osc = ctx.createOscillator(), gain = ctx.createGain();
        osc.frequency.value = hz; gain.gain.value = 0.08;
        osc.connect(gain).connect(ctx.destination);
        osc.start(); osc.stop(ctx.currentTime + 1);
      }
    };
    ring();
    const timer = setInterval(ring, 3000);
    return () => { clearInterval(timer); void ctx.close(); };
  }, [incoming]);
  const running = sending || textState === "connecting" || busy;   // 정지 only while something runs
  const questions = (inCall ? controller.current : textController.current)?.questionRequests;
  const cards = questions ? inputCards.map((card) =>
    <QuestionCard key={card.id} card={card} requests={questions} onError={setError} />) : null;
  const android = boot?.platform === "android";
  const canCall = boot?.voiceSupported !== false;   // a host without a call (web) hides 📞 instead of failing at the microphone
  // 단계 판정(verify_step)은 절차 카드의 진행으로 보인다.
  const outcomes: Record<string, StepOutcome> = {};
  for (const message of chat.messages) for (const tool of toolParts(message)) {
    const input = tool.input as { step?: unknown; outcome?: unknown } | undefined;
    if (toolName(tool) === "verify_step" && tool.state === "output-available" && typeof input?.step === "string"
      && (input.outcome === "ok" || input.outcome === "changed" || input.outcome === "fail")) outcomes[input.step] = input.outcome;
  }
  const lastMessage = chat.messages[chat.messages.length - 1];
  // 로그의 줄: 통화면 대사(ChatMessage), 아니면 useChat 메시지의 parts(추론 요약은 '생각', 글은 말풍선, 도구 호출·결과는 카드, 절차 읽기는 단계 목록) 시간순.
  const entries: Entry[] = call
    ? messages.map((message) => ({ id: message.id, role: message.role, node: <Bubble role={message.role} text={message.text} /> }))
    : chat.messages.flatMap((message) => message.role !== "user" && message.role !== "assistant" ? [] : message.parts.flatMap((part, index): Entry[] => {
      const id = `${message.id}-${index}`, role = message.role as "user" | "assistant";
      if (part.type === "reasoning") {
        const previous = message.parts[index - 1];
        if (previous?.type === "reasoning") return [];   // consecutive reasoning parts fold into the first one's card
        let text = part.text, last = part;
        for (let next = index + 1; next < message.parts.length && message.parts[next].type === "reasoning"; next++) {
          last = message.parts[next] as typeof part; text += "\n\n" + last.text;
        }
        return [{ id, node: <Thinking text={text} streaming={last.state === "streaming"} /> }];
      }
      if (part.type === "text") {
        if (!part.text && role !== "user") return [];
        const isLast = message === lastMessage && !busy && role === "assistant" && !message.parts.slice(index + 1).some((p) => p.type === "text");
        const actions = role === "assistant" && part.text ? <BubbleActions text={part.text} onRetry={isLast ? () => { setError(""); void chat.regenerate(); } : undefined} /> : undefined;
        return [{ id, role, node: <Bubble role={role} text={part.text} actions={actions} /> }];
      }
      if (part.type !== "dynamic-tool" && !part.type.startsWith("tool-")) return [];
      const tool = part as ToolPart, name = toolName(tool);
      const failure = failureOf(tool.output);
      const failed = !!failure || tool.state === "output-error";
      const running = tool.state === "input-available" || tool.state === "input-streaming";
      const card: Entry = { id, node: <ToolCard name={name} label={toolLabel(name)} state={failed ? "output-error" : tool.state} input={tool.input} defaultOpen={failed}
        progress={running && progress?.tool === name ? progress.text : undefined}
        output={failure ? undefined : tool.output} errorText={failure ? toolFailureLabels[failure.code] || failure.message || "처리 실패" : tool.errorText} /> };
      const procedures = name === "read_playbook" && tool.state === "output-available" ? proceduresOf(tool.output) : [];
      return [card, ...procedures.map((procedure, position) => ({ id: `${id}-${procedure.id}`,
        node: <Procedure title={procedure.title} steps={procedure.steps} outcomes={outcomes} defaultOpen={position === 0} /> }))];
    }));
  // 통화 중 도구 실행(음성 세션의 진행 신호)은 대사 뒤에 카드로. 글 대화의 카드는 parts 가 이미 든다.
  const callTools = call ? tools.map((item) => <ToolCard key={item.id} name={item.name} label={toolLabel(item.name)} state={progressState(item.status)}
    errorText={item.code ? toolFailureLabels[item.code] || "처리 실패" : undefined} />) : null;
  const toolsRunning = tools.some((item) => item.status === "running");
  useEffect(() => { lastEntry.current = entries.length ? entries[entries.length - 1].id : null; }, [entries.length]);
  const noticesAfter = (id: string | null) => notices.filter((n) => n.after === id).map((n) => <Bubble key={n.id} role="assistant" text={n.text} />);
  // 대기 중임을 항상 보이게: 응답을 기다리거나 도구가 도는 동안 마지막에 임시 비서 말풍선 한 줄(모델이 첫 글자를 보내기 전에도).
  const lastIsAssistant = entries.length > 0 && entries[entries.length - 1].role === "assistant";
  const pendingWord = textState === "connecting" ? "연결 중…" : toolsRunning ? "도구 실행 중…" : busy || sending ? "생각 중…" : "";
  const pendingBubble = !inCall && pendingWord && (toolsRunning || !lastIsAssistant) ? <Bubble key="pending" role="assistant" text={pendingWord} pending /> : null;
  const status = running ? (chat.status === "streaming" ? "streaming" : "submitted") : "ready";   // 세션 연결 중도 '진행 중'으로; 오류는 배너가 말하니 버튼은 보내기
  // 뼈대(ui/shell.tsx)에 서브트리를 주입한다. 상태와 브리지는 여기, DOM 모양은 뼈대, 스타일은 index.css(토큰 매핑)+style.css.
  const render = (slots?: ShellFrameSlots) => <Shell platform={boot?.platform} {...slots}
    error={error ? <ErrorBanner onClose={() => setError("")}>{error}</ErrorBanner>
      : boot && !boot.configured ? <ErrorBanner>{boot.executor?.googleSignIn === true && boot.authentication?.signedIn !== true ? "Google 계정으로 로그인해 주세요." : "기기가 아직 연결되지 않았습니다."}</ErrorBanner>
      : boot && android && !boot.accessibility && <ErrorBanner>접근성 연결 필요 · 설정</ErrorBanner>}
    conversation={<Pane
      incoming={incoming !== null && !inCall && boot?.configured && <IncomingCall reason={incoming} onAccept={() => void startCall(incoming)} onLater={declineCall} />}
      log={<Log>
        {!call && entries.length === 0 && <Welcome disabled={waiting}
          hint={android ? "앱 열기 · 화면 읽기 · 일 처리" : boot?.platform === "web" ? "절차 · 할 일" : "절차 · 기억 · 할 일"}
          suggestions={[android ? "토스를 열고 현재 화면을 읽어 줘." : "사용할 수 있는 플레이북을 찾아서 알려 줘."]}
          onSuggest={(text) => void send(text).catch(() => {})} />}
        {call && <CallCard kind="start" time={clock(call.startedAt)} />}
        {noticesAfter(null)}
        {entries.map((entry) => <Fragment key={entry.id}>{entry.node}{noticesAfter(entry.id)}</Fragment>)}
        {callTools}
        {pendingBubble}
        {cards}
        {call?.endedAt && <CallCard kind="end" time={clock(call.endedAt)} />}
      </Log>}
      composer={inCall
        ? <CallBar word={callWords[state]} onEnd={() => void controller.current?.stop()} />
        : <>
          <Waiting items={queue} onRemove={(index) => setQueue((old) => old.filter((_, i) => i !== index))} />
          <Composer status={status} disabled={boot?.configured === false} onSend={send} onStop={() => void stopCurrent()}
            onCall={canCall ? () => void startCall() : undefined} callDisabled={settling} />
        </>}
    />} />;
  return frame ? frame({ boot, active: inCall || textState !== "idle", refresh: async () => {
    const latest = await bridge.call<Bootstrap>("bootstrap");
    if (mounted.current) apply(latest);
  } }, render) : render();
}
