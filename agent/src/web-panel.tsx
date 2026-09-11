// 웹(hub) 프레임: 상단 바(뽀미 · 로그인/나)와 콘텐츠(기록 탭 + 샌드박스 기록 프레임). 대화는 공통 ChatPanel 그대로.
// 브라우저 전용 계층(Supabase 로그인, 기기 키, 복호화, 프레임 렌더러)은 hub가 소유하고 host 객체로만 들어온다.
import { useEffect, useRef, useState, useSyncExternalStore, type KeyboardEvent, type MouseEvent, type ReactNode } from "react";
import { UserRound, X } from "lucide-react";
import type { Bootstrap } from "./bridge";
import type { WebHostSource } from "./web-host";
import type { TranscriptSync } from "./transcripts";
import { RecordsHeader } from "./ui/workbench";
import type { ShellFrameSlots } from "./ui/shell";

export type WebRecordView = { readonly id: string; readonly label: string };
export type WebRecordConnection = {
  readonly status: "ready" | "waiting-key";
  readonly workspace: { readonly id: string; readonly name: string };
  readonly device: { readonly id: string; readonly label: string; readonly platform: string } | null;
  readonly recordNames: readonly string[];
};
/** The public state of hub's record session (record-session.js). Never tokens, keys or plaintext. */
export type WebRecordsState = {
  readonly status: "idle" | "connecting" | "waiting-key" | "reading" | "ready" | "missing" | "error";
  readonly busy: boolean;
  readonly connection: WebRecordConnection | null;
  readonly record: { readonly name: string; readonly version: string; readonly updatedAt: string | null } | null;
  readonly error: { readonly code?: string; readonly phase: "connect" | "read" } | null;
};
export type WebRecords = {
  readonly views: readonly WebRecordView[];
  getState(): WebRecordsState;
  subscribe(listener: () => void): () => void;
  select(view: string): void;
  refresh(): void;
  /** Where the browser-only renderer mounts its sandboxed frames. Returns the detach function. */
  attach(container: HTMLElement): () => void;
};
export type WebWorkbenchHost = { readonly source: WebHostSource; readonly records: WebRecords; readonly transcripts?: TranscriptSync };

const failureTexts: Record<string, string> = {
  storage: "브라우저 저장 공간을 사용할 수 없어요. Safari 설정을 확인한 뒤 다시 열어 주세요.",
  connection: "연결을 확인하지 못했어요. 인터넷에 연결한 뒤 다시 시도해 주세요.",
  authentication: "로그인을 다시 확인해 주세요. Google 로그인 버튼으로 시작할 수 있어요.",
  unavailable: "로그인은 ppomi.muilyzz.com에서 시작해 주세요.",
  cleanup: "계정 전환을 마치지 못했어요. 이 창을 닫고 다시 열어 주세요.",
  unsupported: "이 브라우저는 기록을 여는 암호화 기능을 지원하지 않아요. 최신 Safari 또는 Chrome에서 열어 주세요.",
  permission: "이 기기의 기록 접근을 확인하지 못했어요. 같은 계정의 Mac에서 기록 연결 상태를 확인해 주세요.",
  invalid: "기록의 암호화 또는 형식을 확인하지 못했어요. Mac의 공유 상태를 확인한 뒤 다시 시도해 주세요.",
  oversized: "이 기록은 브라우저에서 열 수 있는 크기를 넘었어요. Mac 앱에서 확인해 주세요.",
  render: "기록 화면을 열지 못했어요. 새로고침한 뒤 다시 시도해 주세요.",
};
export type RecordTexts = {
  workspace: string; device: string; sync: string; status: string; version: string;
  message: { heading: string; body: string; link?: boolean } | null;
};
/** The same words the vanilla home used, as one pure mapping from session state to the pane and the account sheet. */
export function recordTexts(state: WebRecordsState): RecordTexts {
  const texts: RecordTexts = { workspace: "", device: "", sync: "", status: "", version: "", message: null };
  if (state.status === "idle") return texts;
  if (state.connection) {
    texts.workspace = state.connection.workspace.name;
    texts.device = "웹 브라우저 · 읽기";
    texts.sync = "기록 연결됨 · 보고 있는 기록을 자동으로 확인합니다.";
  }
  switch (state.status) {
    case "connecting":
      texts.workspace = "Google 로그인 완료"; texts.device = "기기 확인 중"; texts.sync = "공유된 기록에 연결하고 있습니다.";
      texts.status = "기록 연결을 확인하고 있습니다.";
      texts.message = { heading: "기록을 연결하고 있습니다", body: "처음 연결할 때는 Mac이 켜져 있어야 합니다." };
      break;
    case "waiting-key":
      texts.sync = "Mac이 이 브라우저에 기록 키를 연결하기를 기다리고 있어요."; texts.status = "기록 키 연결 대기";
      texts.message = { heading: "사용 중인 Mac에서 뽀미를 열어 주세요",
        body: "같은 Google 계정으로 로그인된 Mac이 켜져 있으면 기록이 연결됩니다. 연결이 끝나면 이 화면에 자동으로 표시됩니다.", link: true };
      break;
    case "reading":
      texts.status = "최신 기록을 확인하고 있습니다.";
      if (!state.record) texts.message = { heading: "기록을 불러오고 있습니다", body: "" };
      break;
    case "ready": {
      const updated = state.record?.updatedAt ? new Date(state.record.updatedAt) : null;
      texts.status = updated && Number.isFinite(+updated) ? `Mac에서 공유 · ${updated.toLocaleString("ko-KR")}` : "공유된 기록";
      if (state.record) texts.version = `버전 ${state.record.version}`;
      break;
    }
    case "missing":
      texts.status = "공유된 기록 없음";
      texts.message = { heading: "아직 공유되지 않은 기록입니다",
        body: state.error?.code === "unshared" ? "Mac의 뽀미에서 이 기록을 공유하면 여기에 표시됩니다." : "Mac에서 기록을 공유하면 이곳에 표시됩니다." };
      break;
    case "error": {
      const reason = failureTexts[state.error?.code ?? ""];
      if (state.error?.phase === "connect") {
        texts.sync = reason ?? failureTexts.invalid; texts.status = "기록 연결 확인 필요";
        texts.message = { heading: "기록 연결을 확인해 주세요", body: reason ?? failureTexts.invalid };
      } else {
        texts.status = "다시 시도할 수 있습니다.";
        texts.message = { heading: "기록을 열지 못했습니다", body: reason ?? failureTexts.render };
      }
      break;
    }
    default: {
      const exhaustive: never = state.status;
      return exhaustive;
    }
  }
  return texts;
}

/** Record tabs, one status line and the container the sandboxed frames render into. The frames' DOM is not React's. */
function WebRecordsPane({ records, state }: { records: WebRecords; state: WebRecordsState }) {
  const [view, setView] = useState(records.views[0]?.id ?? "");
  const container = useRef<HTMLDivElement>(null);
  const tabs = useRef<(HTMLButtonElement | null)[]>([]);
  useEffect(() => {
    const element = container.current;
    if (!element) return;
    return records.attach(element);
  }, [records]);
  const choose = (id: string) => { if (id !== view) { setView(id); records.select(id); } };
  const keyDown = (event: KeyboardEvent<HTMLElement>, index: number) => {
    const count = records.views.length;
    const next = event.key === "ArrowRight" || event.key === "ArrowDown" ? (index + 1) % count
      : event.key === "ArrowLeft" || event.key === "ArrowUp" ? (index + count - 1) % count
      : event.key === "Home" ? 0 : event.key === "End" ? count - 1 : -1;
    if (next < 0) return;
    event.preventDefault();
    tabs.current[next]?.focus();
    choose(records.views[next].id);
  };
  const texts = recordTexts(state);
  return <>
    <RecordsHeader>
      <div role="tablist" aria-label="기록 종류">
        {records.views.map((item, index) => <button key={item.id} ref={element => { tabs.current[index] = element; }} type="button" role="tab"
          aria-selected={item.id === view} tabIndex={item.id === view ? 0 : -1} onClick={() => choose(item.id)} onKeyDown={event => keyDown(event, index)}>{item.label}</button>)}
      </div>
      <button className="text web-refresh" type="button" disabled={state.status === "idle" || state.busy} onClick={() => records.refresh()}>새로고침</button>
    </RecordsHeader>
    <p className="web-record-status" role="status" aria-live="polite">{texts.status}{texts.version && <span> · {texts.version}</span>}</p>
    <div className="records-body web-records-body">
      {texts.message && <div className="record-empty">
        <span className="empty-symbol" aria-hidden="true">⌁</span>
        <h3>{texts.message.heading}</h3>
        {texts.message.body && <p>{texts.message.body}</p>}
        {texts.message.link && <a className="web-link-button" href="/download">Mac 앱 설치 안내</a>}
      </div>}
      <div ref={container} className="web-record-frames" hidden={texts.message !== null} />
    </div>
  </>;
}

/** A native <dialog>: focus trap, Escape and backdrop without injected styles, so the page keeps style-src 'self'. */
function Sheet({ open, onClose, labelledBy, children }: { open: boolean; onClose(): void; labelledBy: string; children: ReactNode }) {
  const ref = useRef<HTMLDialogElement>(null);
  useEffect(() => {
    const dialog = ref.current;
    if (!dialog || typeof dialog.showModal !== "function") return;
    if (open && !dialog.open) dialog.showModal();
    else if (!open && dialog.open) dialog.close();
  }, [open]);
  // The backdrop's clicks arrive on the dialog element itself; clicks inside land on the body wrapper.
  const backdrop = (event: MouseEvent<HTMLDialogElement>) => { if (event.target === event.currentTarget) onClose(); };
  return <dialog ref={ref} className="web-sheet executor-settings" aria-labelledby={labelledBy} onClose={onClose} onClick={backdrop}>
    <div className="web-sheet-body web-account">{children}</div>
  </dialog>;
}

type Props = { boot?: Bootstrap; active: boolean; refresh(): Promise<void>; host: WebWorkbenchHost; children(slots: ShellFrameSlots): ReactNode };

/** Browser-owned controls: sign-in, the account sheet and the records pane. None of this is part of the agent's tool set. */
export function WebPanel({ active, host, children }: Props) {
  const hostState = useSyncExternalStore(host.source.subscribe, host.source.getState, host.source.getState);
  const records = useSyncExternalStore(host.records.subscribe, host.records.getState, host.records.getState);
  const [open, setOpen] = useState(false);
  const [pending, setPending] = useState(false);
  const [error, setError] = useState("");
  const account = hostState.account;
  useEffect(() => { if (!account) setOpen(false); }, [account]);
  const perform = async (body: () => Promise<unknown>) => {
    setPending(true); setError("");
    try { await body(); }
    catch (failure) { setError(failure instanceof Error && failure.message ? failure.message : "요청을 처리하지 못했습니다."); }
    finally { setPending(false); }
  };
  const texts = recordTexts(records);
  const topBar = <div className="executor-panel web-panel">
    <nav className="executor-toolbar" aria-label="앱 탐색">
      <strong className="web-brand">뽀미</strong>
      {hostState.notice && <p className={"web-notice" + (hostState.noticeIsError ? " error" : "")} role={hostState.noticeIsError ? "alert" : "status"}>{hostState.notice}</p>}
      <div className="executor-toolbar-account">
        {account
          ? <button className="executor-nav-button" type="button" aria-label="나 · 계정" aria-haspopup="dialog" disabled={pending} onClick={() => setOpen(true)}>
            <UserRound aria-hidden="true" /><span>나</span>
          </button>
          : <button className="executor-nav-button" type="button" aria-label="Google 계정으로 로그인" disabled={pending}
            onClick={() => void perform(() => host.source.signIn())}>
            <UserRound aria-hidden="true" /><span>로그인</span>
          </button>}
      </div>
    </nav>
    <Sheet open={open && account !== null} onClose={() => setOpen(false)} labelledBy="web-sheet-title">
        <div className="executor-sheet-heading"><h2 id="web-sheet-title">나</h2>
          <button type="button" className="executor-nav-button executor-icon-button" aria-label="닫기" onClick={() => setOpen(false)}><X aria-hidden="true" /></button></div>
        <section aria-labelledby="web-account-title">
          <h3 id="web-account-title">계정</h3>
          <p className="web-account-identity"><strong>{account?.name || "내 계정"}</strong>{account?.email && <span>{account.email}</span>}</p>
          <div className="executor-setting-actions">
            <button type="button" disabled={pending || active} title={active ? "대화를 종료한 뒤 계정을 변경할 수 있습니다." : undefined}
              onClick={() => void perform(async () => { await host.source.signOut(); setOpen(false); })}>로그아웃</button>
          </div>
          {active && <p className="executor-hint">대화를 종료한 뒤 계정을 변경할 수 있습니다.</p>}
        </section>
        <section aria-labelledby="web-connection-title">
          <h3 id="web-connection-title">기록 연결</h3>
          <dl className="web-connection">
            <div><dt>계정</dt><dd>{texts.workspace || "확인 중"}</dd></div>
            <div><dt>이 기기</dt><dd>{texts.device || "확인 중"}</dd></div>
          </dl>
          {texts.sync && <p className="executor-hint" role="status">{texts.sync}</p>}
          <p className="executor-hint">대화는 이 브라우저에서, 기기 제어와 통화는 설치한 뽀미 앱에서 이용하세요.</p>
        </section>
        <nav className="web-account-links" aria-label="안내">
          <a href="/download">앱 설치 안내</a>
          <a href="/privacy">개인정보 처리방침</a>
        </nav>
    </Sheet>
    {error && <p className="executor-error" role="alert">{error}<button type="button" onClick={() => setError("")}>닫기</button></p>}
  </div>;
  const contentPane = account ? <WebRecordsPane records={host.records} state={records} /> : undefined;
  return children({ topBar, contentPane, contentLabel: "내 기록", contentActionLabel: "기록 보기" });
}
