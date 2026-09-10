import React, { Fragment, useEffect, useRef, useState } from "react";
import { useChat, type UseChatHelpers } from "@ai-sdk/react";
import type { UIMessage } from "ai";
import { toolLabel } from "./tool-label";
import { createRoot } from "react-dom/client";
import { createBridge, type Bootstrap } from "./bridge";
import { VoiceController, type VoiceState, TextController, type TextState, type ChatMessage, type ToolProgress } from "./voice";
import { type InputCard } from "./questions";
import { QuestionCard } from "./question-cards";
import { Shell, ErrorBanner, Conversation, IncomingCall, ToolSummary, ChatLog, Welcome, Message, CallCard, Composer, CallBar,
  type ToolRow } from "./ui/shell";
import "./tokens.css";
import "./style.css";

/** 어르신의 큰 글씨 설정까지: 글자만이 아니라 여백·컨트롤도 같이 커지도록 루트 배율 하나로 적용한다. */
function applyUIScale(b: Bootstrap) {
  const scale = typeof b.uiScale === "number" && Number.isFinite(b.uiScale) ? Math.min(3, Math.max(0.75, b.uiScale)) : 1;
  document.documentElement.style.setProperty("--ui-scale", String(scale));
  if (typeof b.dark === "boolean") document.documentElement.dataset.theme = b.dark ? "dark" : "light";
}
const bridge = createBridge();
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
function App() {
  const [boot, setBoot] = useState<Bootstrap>();
  const [state, setState] = useState<VoiceState>("idle");
  const [error, setError] = useState("");
  const [textState, setTextState] = useState<TextState>("idle");
  const [messages, setMessages] = useState<ChatMessage[]>([]);
  const [tools, setTools] = useState<ToolProgress[]>([]);
  const [inputCards, setInputCards] = useState<InputCard[]>([]);
  const [draft, setDraft] = useState("");
  const [sending, setSending] = useState(false);
  const [settling, setSettling] = useState(false);
  const [call, setCall] = useState<Call | null>(null);
  const [incoming, setIncoming] = useState<string | null>(null);
  const [notices, setNotices] = useState<{ id: string; text: string; after: string | null }[]>([]);   // 비서의 톡(네이티브 사람 차례)
  const lastMessage = useRef<string | null>(null);   // a notice sits after the message that was last when it arrived
  const missed = useRef<ReturnType<typeof setTimeout> | undefined>(undefined);   // 벨은 45초면 끊는다(부재중)
  const actionEpoch = useRef(0);
  const connected = useRef(false);   // a call that never connected leaves no cards (the error banner says why)
  const inCallRef = useRef(false);   // rings during a call are dropped (the first-render closure below has no state)
  const bootRef = useRef<Bootstrap | undefined>(undefined);      // window hooks are installed once; they read the latest values through refs
  const textStateRef = useRef<TextState>("idle");
  const chatLog = useRef<HTMLDivElement>(null);
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
        setTools([]); setDraft(""); setSending(false); setSettling(true);
        chatRef.current?.setMessages([]);
        queueMicrotask(() => { void textController.current?.whenStopped().finally(() => setSettling(false)); });
      }
    },
    setError, trackTools, setInputCards,
  );
  // 글 대화: Vercel AI SDK useChat. 전송·상태(submitted/streaming/ready/error)·말풍선은 SDK가, 도구 실행과 세션 수명은 TextController가 맡는다.
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
    setDraft(""); setSending(false);
    chat.stop();
    await textController.current?.stop();
    await controller.current?.stop();
  };
  /** 걸기(또는 받기): 글 대화가 열려 있으면 닫고 통화를 연다. 로그는 통화 카드부터 다시 쌓인다. refs만 읽어 훅에서도 안전하다. */
  const clearIncoming = () => { clearTimeout(missed.current); setIncoming(null); };
  const startCall = async (reason?: string) => {
    const b = bootRef.current;
    if (!b?.configured || inCallRef.current) return;
    setError(""); clearIncoming();
    if (textStateRef.current !== "idle") await textController.current?.stop();
    await controller.current?.whenStopped();
    setMessages([]); setNotices([]); setCall({ startedAt: Date.now() });
    await controller.current?.start(b, reason);
  };
  /** 나중에: 띠를 내리고 네이티브 벨(Android OS 통화)도 끊는다. */
  const declineCall = () => { clearIncoming(); void bridge.call("declineCall", {}).catch(() => {}); };
  const send = async () => {
    const value = draft.trim();
    if (!value || value.length > 12_000 || !boot?.configured || inCall || waiting) return;
    const epoch = actionEpoch.current;
    setSending(true); setError("");
    try {
      if (textState === "idle") await textController.current?.start(boot);
      if (epoch !== actionEpoch.current || textStateRef.current !== "ready") return;
      setDraft("");
      void chat.sendMessage({ text: value });   // resolves when the turn ends; status tracks it
    } finally { if (epoch === actionEpoch.current) setSending(false); }
  };
  const apply = (b: Bootstrap) => {
    applyUIScale(b); bootRef.current = b; setBoot(b);
    if (b.answerCall) void startCall(b.answerCall);   // answered on the OS call screen before the page was ready
  };
  const load = async () => {
    try {
      apply(await bridge.call<Bootstrap>("bootstrap"));
    } catch {
      setError("서버 연결 실패");
    }
  };
  useEffect(() => {
    void load();
    const refreshCapabilities = () => {
      if (document.visibilityState === "hidden") return;
      void bridge.call<Bootstrap>("bootstrap").then(apply).catch(() => {});
    };
    window.ppomiAnswerCall = (reason: string) => { void startCall(typeof reason === "string" ? reason : undefined); };
    window.ppomiVoiceStop = () => {
      void stopCurrent();
    };
    // 네이티브가 사람 차례(승인·질문)나 예약된 일로 부른다. 빈 용건 = 해결됨(띠를 내린다). 통화 중이면 이미 말하고 있으니 버린다.
    window.ppomiIncomingCall = (reason: string) => {
      if (inCallRef.current) return;
      clearTimeout(missed.current);
      const text = typeof reason === "string" && reason ? reason : null;
      setIncoming(text);
      if (text) missed.current = setTimeout(declineCall, 45_000);
    };
    window.ppomiNotice = (text: string) => {
      if (typeof text === "string" && text) setNotices((old) => [...old, { id: crypto.randomUUID(), text, after: lastMessage.current }]);
    };
    const unload = () => void stopCurrent();
    window.addEventListener("pagehide", unload);
    window.addEventListener("focus", refreshCapabilities);
    document.addEventListener("visibilitychange", refreshCapabilities);
    return () => {
      unload();
      window.removeEventListener("pagehide", unload);
      window.removeEventListener("focus", refreshCapabilities);
      document.removeEventListener("visibilitychange", refreshCapabilities);
      delete window.ppomiVoiceStop;
      delete window.ppomiIncomingCall;
      delete window.ppomiNotice;
      delete window.ppomiAnswerCall;
    };
  }, []);
  // 로그의 줄: 통화면 대사(ChatMessage), 아니면 useChat 메시지의 글 부분만(도구 호출·결과는 위의 실행 내역에만 보인다).
  const rows: ChatMessage[] = call ? messages : chat.messages.flatMap((message) => {
    if (message.role !== "user" && message.role !== "assistant") return [];
    const text = message.parts.flatMap((part) => part.type === "text" ? [part.text] : []).join("");
    return text || message.role === "user" ? [{ id: message.id, role: message.role, text, status: "completed" as const }] : [];
  });
  useEffect(() => {
    const log = chatLog.current;
    if (log) log.scrollTop = log.scrollHeight;
  }, [rows.length, tools, inputCards, call]);
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
  const busy = chat.status === "submitted" || chat.status === "streaming";
  const waiting = sending || settling || textState === "connecting" || busy;
  const running = sending || textState === "connecting" || busy;   // 정지 only while something runs
  const questions = (inCall ? controller.current : textController.current)?.questionRequests;
  const cards = questions ? inputCards.map((card) =>
    <QuestionCard key={card.id} card={card} requests={questions} onError={setError} />) : null;
  useEffect(() => { lastMessage.current = rows.length ? rows[rows.length - 1].id : null; }, [rows.length]);
  const noticesAfter = (id: string | null) => notices.filter((n) => n.after === id).map((n) => <Message key={n.id} role="assistant" text={n.text} />);
  const android = boot?.platform === "android";
  const toolRows: ToolRow[] = tools.map((item) => ({
    id: item.id, status: item.status, label: toolLabel(item.name),
    detail: (item.status === "running" ? "실행 중" : item.status === "success" ? "완료" : "실패")
      + (item.code ? ` · ${toolFailureLabels[item.code] || "처리 실패"}` : ""),
  }));
  const toolsRunning = tools.some((item) => item.status === "running"), failed = tools.some((item) => item.status === "error");
  // 대기 중임을 항상 보이게: 응답을 기다리거나 도구가 도는 동안 마지막에 임시 비서 말풍선 한 줄(모델이 첫 글자를 보내기 전에도).
  const lastIsAssistant = rows.length > 0 && rows[rows.length - 1].role === "assistant";
  const pendingWord = textState === "connecting" ? "연결 중…" : toolsRunning ? "도구 실행 중…" : busy || sending ? "생각 중…" : "";
  const pendingBubble = !inCall && pendingWord && (toolsRunning || !lastIsAssistant) ? <Message key="pending" role="assistant" text={pendingWord} /> : null;
  // 뼈대(ui/shell.tsx)에 서브트리를 주입한다. 상태와 브리지는 여기, DOM 모양은 뼈대, 스타일은 style.css.
  return <Shell platform={boot?.platform}
    error={error ? <ErrorBanner onClose={() => setError("")}>{error}</ErrorBanner>
      : boot && !boot.configured ? <ErrorBanner>설정에서 서버 주소</ErrorBanner>
      : boot && android && !boot.accessibility && <ErrorBanner>접근성 연결 필요 · 설정</ErrorBanner>}
    conversation={<Conversation
      incoming={incoming !== null && !inCall && boot?.configured && <IncomingCall reason={incoming} onAccept={() => void startCall(incoming)} onLater={declineCall} />}
      tools={tools.length > 0 && <ToolSummary rows={toolRows}
        summary={`${toolsRunning ? "실행 중" : "실행 내역"} · ${tools.length}개${failed ? " · 실패" : ""}`} />}
      log={<ChatLog logRef={chatLog}>
        {!call && rows.length === 0 && <Welcome disabled={waiting}
          hint={android ? "앱 열기 · 화면 읽기 · 일 처리" : "절차 · 기억 · 할 일"}
          suggestion={android ? "토스 화면 읽기 ↗" : "플레이북 찾기 ↗"}
          onSuggest={() => setDraft(android ? "토스를 열고 현재 화면을 읽어 줘." : "사용할 수 있는 플레이북을 찾아서 알려 줘.")} />}
        {call && <CallCard kind="start" time={clock(call.startedAt)} />}
        {noticesAfter(null)}
        {rows.map((message) => <Fragment key={message.id}><Message role={message.role} text={message.text} />{noticesAfter(message.id)}</Fragment>)}
        {pendingBubble}
        {cards}
        {call?.endedAt && <CallCard kind="end" time={clock(call.endedAt)} />}
      </ChatLog>}
      composer={inCall
        ? <CallBar word={callWords[state]} onEnd={() => void controller.current?.stop()} />
        : <Composer value={draft} disabled={!boot?.configured} canSend={!!boot?.configured && !!draft.trim() && !waiting}
            onChange={setDraft} onSend={() => void send()} onStop={running ? () => void stopCurrent() : undefined}
            onCall={() => void startCall()} callDisabled={settling} />}
    />} />;
}
createRoot(document.getElementById("root")!).render(<App />);
