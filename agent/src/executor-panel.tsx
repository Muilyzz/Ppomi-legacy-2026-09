import { useEffect, useRef, useState, type ReactNode } from "react";
import { type Bootstrap } from "./bridge";
import { manageExecutor, type ExecutorStatus } from "./tauri-host";
import { BookOpen, Settings, UserRound, X } from "lucide-react";
import { Dialog, DialogContent, DialogTitle, DialogClose } from "./components/ui/dialog";
import type { ShellFrameSlots } from "./ui/shell";

export type ExecutorSlots = ShellFrameSlots;
type Props = { boot?: Bootstrap; active: boolean; refresh(): Promise<void>; children(slots: ExecutorSlots): ReactNode };

/** App-owned controls. Their management methods are not part of the agent's tool set. */
export function ExecutorPanel({ boot, active, refresh, children }: Props) {
  const [status, setStatus] = useState<ExecutorStatus>();
  const [open, setOpen] = useState(false);
  const [error, setError] = useState("");
  const [pending, setPending] = useState(false);
  const polling = useRef(false);
  const refreshRef = useRef(refresh);
  refreshRef.current = refresh;
  const poll = async () => {
    if (polling.current) return;
    polling.current = true;
    try { setStatus(await manageExecutor<ExecutorStatus>("status")); }
    catch { /* Bootstrap owns connection errors. A missing status never creates an approval. */ }
    finally { polling.current = false; }
  };
  useEffect(() => {
    let disposed = false;
    const tick = async () => { if (!disposed) await poll(); };
    void tick();
    const timer = setInterval(() => void tick(), 1000);
    const focused = () => { void refreshRef.current().catch(() => {}); void tick(); };
    window.addEventListener("focus", focused);
    return () => { disposed = true; clearInterval(timer); window.removeEventListener("focus", focused); };
  }, []);
  const perform = async (body: () => Promise<unknown>) => {
    setPending(true); setError("");
    try { await body(); await refresh(); await poll(); return true; }
    catch (error) { setError(error instanceof Error ? error.message : "설정을 적용하지 못했습니다."); return false; }
    finally { setPending(false); }
  };
  const approval = status?.approval;
  const signedIn = boot?.authentication?.signedIn === true;
  const canViewRecords = boot?.platform === "macos" || boot?.platform === "android";
  const canSignIn = boot?.executor?.googleSignIn === true;
  const topBar = <div className="executor-panel">
    <nav className="executor-toolbar" aria-label="앱 탐색">
      {canViewRecords && <button className="executor-nav-button" type="button" disabled={pending}
        onClick={() => void perform(() => manageExecutor("openRecords"))}><BookOpen aria-hidden="true" /><span>기록</span></button>}
      <div className="executor-toolbar-account">
        {canSignIn && <button className="executor-nav-button" type="button"
          aria-label={signedIn ? "나 · 계정" : "Google 계정으로 로그인"}
          title={active ? "대화를 종료한 뒤 계정을 변경할 수 있습니다." : signedIn ? "나 · 계정" : "Google 계정으로 로그인"}
          disabled={pending || active} onClick={() => void perform(() => manageExecutor("openAccount"))}>
          <UserRound aria-hidden="true" /><span>{signedIn ? "나" : "로그인"}</span>
        </button>}
        <button className="executor-nav-button executor-icon-button" type="button" aria-label="설정" title={active ? "대화를 종료한 뒤 설정을 변경할 수 있습니다." : "설정"}
          disabled={pending || active || !boot} onClick={() => {
            if (boot?.platform === "windows") setOpen(true);
            else void perform(() => manageExecutor("openSettings"));
          }}><Settings aria-hidden="true" /></button>
      </div>
    </nav>
    <Dialog open={open && boot?.platform === "windows"} onOpenChange={setOpen}>
      <DialogContent className="executor-settings" showCloseButton={false} aria-describedby={undefined}>
      <div className="executor-sheet-heading"><DialogTitle>설정</DialogTitle>
        <DialogClose className="executor-nav-button executor-icon-button" aria-label="설정 닫기"><X aria-hidden="true" /></DialogClose></div>
      <div className="executor-setting-actions">
        <button type="button" disabled={pending || active} onClick={() => void perform(() => manageExecutor("configureDevice"))}>개발용 기기 등록</button>
      </div>
      {active && <p className="executor-hint">연결 설정과 앱 허용은 대화를 종료한 뒤 변경할 수 있습니다.</p>}
      {status?.availableApps && <ControlApps apps={status.availableApps} disabled={pending || active}
        save={(packageNames) => perform(() => manageExecutor("setControlApps", { packageNames }))} />}
      </DialogContent>
    </Dialog>
    {error && <p className="executor-error" role="alert">{error}<button type="button" onClick={() => setError("")}>닫기</button></p>}
  </div>;
  const contentPane = approval && <section className="executor-approval" aria-label="사용자 확인" aria-live="polite">
    <p>{approval.text}</p>
    <div>{approval.options.map((choice) => <button key={choice} type="button" disabled={pending}
      onClick={() => void perform(() => manageExecutor("answerApproval", { id: approval.id, choice }))}>{choice}</button>)}</div>
  </section>;
  return children({ topBar, contentPane, contentLabel: "사용자 확인", contentActionLabel: "승인 요청" });
}

function ControlApps({ apps, disabled, save }: { apps: NonNullable<ExecutorStatus["availableApps"]>; disabled: boolean; save(names: string[]): Promise<boolean> }) {
  const [selected, setSelected] = useState<string[] | null>(null);
  const current = selected ?? apps.filter((app) => app.allowed).map((app) => app.packageName);
  return <fieldset disabled={disabled}>
    <legend>제어할 앱</legend>
    {apps.length === 0 && <p>제어할 앱을 먼저 열어 주세요.</p>}
    <div className="executor-app-list">{apps.map((app) => <label key={app.packageName}>
      <input type="checkbox" checked={current.includes(app.packageName)} onChange={(event) =>
        setSelected(event.target.checked ? [...current, app.packageName] : current.filter((id) => id !== app.packageName))} />{app.label}
    </label>)}</div>
    <button type="button" onClick={() => void save(current.filter((id) => apps.some((app) => app.packageName === id))).then((saved) => { if (saved) setSelected(null); })}>앱 허용 저장</button>
  </fieldset>;
}
