import { useEffect, useRef, useState, type ReactNode } from "react";
import { type Bootstrap } from "./bridge";
import { manageExecutor, type ExecutorAccount, type ExecutorStatus } from "./tauri-host";
import { BookOpen, Settings, UserRound, X } from "lucide-react";
import { Dialog, DialogContent, DialogTitle, DialogClose } from "./components/ui/dialog";
import type { ShellFrameSlots } from "./ui/shell";

export type ExecutorSlots = ShellFrameSlots;
type Manage = typeof manageExecutor;
type Props = { boot?: Bootstrap; active: boolean; refresh(): Promise<void>; children(slots: ExecutorSlots): ReactNode;
  /** Storybook injects an offline stand-in; the app always talks to its Tauri executor. */
  manage?: Manage };

/** App-owned controls. Their management methods are not part of the agent's tool set. */
export function ExecutorPanel({ boot, active, refresh, children, manage = manageExecutor }: Props) {
  const [status, setStatus] = useState<ExecutorStatus>();
  const [open, setOpen] = useState(false);
  const [accountOpen, setAccountOpen] = useState(false);
  const [error, setError] = useState("");
  const [pending, setPending] = useState(false);
  const [signingIn, setSigningIn] = useState(false);
  const polling = useRef(false);
  const refreshRef = useRef(refresh);
  refreshRef.current = refresh;
  const manageRef = useRef(manage);
  manageRef.current = manage;
  const poll = async () => {
    if (polling.current) return;
    polling.current = true;
    try { setStatus(await manageRef.current<ExecutorStatus>("status")); }
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
  // The owner's approval arrives in the background (the executor polls the server); the conversation follows the fresh bootstrap.
  useEffect(() => {
    if (!boot || status?.configured === undefined || status.configured === boot.configured) return;
    void refreshRef.current().catch(() => {});
  }, [status?.configured, boot?.configured]);
  const perform = async (body: () => Promise<unknown>) => {
    setPending(true); setError("");
    try { await body(); await refresh(); await poll(); return true; }
    catch (error) { setError(error instanceof Error ? error.message : "설정을 적용하지 못했습니다."); return false; }
    finally { setPending(false); }
  };
  const approval = status?.approval;
  const windows = boot?.platform === "windows";
  // Until the first status poll answers, the bootstrap's presentation state stands in.
  const account: ExecutorAccount | undefined = status?.account ?? (boot?.authentication ? {
    signedIn: boot.authentication.signedIn === true, registered: boot.authentication.signedIn === true,
    approved: boot.authentication.approved === true, pendingApproval: boot.authentication.pendingApproval === true,
    displayName: boot.authentication.displayName,
  } : undefined);
  const signedIn = account?.signedIn === true;
  const canViewRecords = boot?.platform === "macos" || boot?.platform === "android";
  const canSignIn = boot?.executor?.googleSignIn === true;
  const developerImport = status?.capabilities?.developmentDeviceImport === true;
  const signIn = () => {
    setSigningIn(true);
    void perform(() => manage("signIn")).finally(() => setSigningIn(false));
  };
  const topBar = <div className="executor-panel">
    <nav className="executor-toolbar" aria-label="앱 탐색">
      {canViewRecords && <button className="executor-nav-button" type="button" disabled={pending}
        onClick={() => void perform(() => manage("openRecords"))}><BookOpen aria-hidden="true" /><span>기록</span></button>}
      <div className="executor-toolbar-account">
        {canSignIn && <button className="executor-nav-button" type="button"
          aria-label={signedIn ? "나 · 계정" : "Google 계정으로 로그인"}
          title={active ? "대화를 종료한 뒤 계정을 변경할 수 있습니다." : signedIn ? "나 · 계정" : "Google 계정으로 로그인"}
          disabled={pending || active} onClick={() => {
            if (windows) setAccountOpen(true);
            else void perform(() => manage("openAccount"));
          }}>
          <UserRound aria-hidden="true" /><span>{signedIn ? "나" : "로그인"}</span>
        </button>}
        <button className="executor-nav-button executor-icon-button" type="button" aria-label="설정" title={active ? "대화를 종료한 뒤 설정을 변경할 수 있습니다." : "설정"}
          disabled={pending || active || !boot} onClick={() => {
            if (windows) setOpen(true);
            else void perform(() => manage("openSettings"));
          }}><Settings aria-hidden="true" /></button>
      </div>
    </nav>
    <Dialog open={accountOpen && windows} onOpenChange={setAccountOpen}>
      <DialogContent className="executor-settings executor-account" showCloseButton={false} aria-describedby={undefined}>
        <div className="executor-sheet-heading"><DialogTitle>계정</DialogTitle>
          <DialogClose className="executor-nav-button executor-icon-button" aria-label="계정 닫기"><X aria-hidden="true" /></DialogClose></div>
        <AccountSection account={account} busy={pending || active} signingIn={signingIn} signIn={signIn}
          refresh={() => void perform(() => manage("refreshAccount"))}
          signOut={() => void perform(() => manage("signOut"))} />
        {active && <p className="executor-hint">대화를 종료한 뒤 계정을 변경할 수 있습니다.</p>}
      </DialogContent>
    </Dialog>
    <Dialog open={open && windows} onOpenChange={setOpen}>
      <DialogContent className="executor-settings" showCloseButton={false} aria-describedby={undefined}>
      <div className="executor-sheet-heading"><DialogTitle>설정</DialogTitle>
        <DialogClose className="executor-nav-button executor-icon-button" aria-label="설정 닫기"><X aria-hidden="true" /></DialogClose></div>
      {developerImport && <div className="executor-setting-actions">
        <button type="button" disabled={pending || active} onClick={() => void perform(() => manage("configureDevice"))}>개발용 기기 등록</button>
        <p className="executor-hint">개발자 전용(PPOMI_DEVELOPER_DEVICE_IMPORT=1). 제품 로그인은 계정 › Google 로그인입니다.</p>
      </div>}
      {active && <p className="executor-hint">연결 설정과 앱 허용은 대화를 종료한 뒤 변경할 수 있습니다.</p>}
      {status?.availableApps && <ControlApps apps={status.availableApps} disabled={pending || active}
        save={(packageNames) => perform(() => manage("setControlApps", { packageNames }))} />}
      </DialogContent>
    </Dialog>
    {error && <p className="executor-error" role="alert">{error}<button type="button" onClick={() => setError("")}>닫기</button></p>}
  </div>;
  const contentPane = approval && <section className="executor-approval" aria-label="사용자 확인" aria-live="polite">
    <p>{approval.text}</p>
    <div>{approval.options.map((choice) => <button key={choice} type="button" disabled={pending}
      onClick={() => void perform(() => manage("answerApproval", { id: approval.id, choice }))}>{choice}</button>)}</div>
  </section>;
  return children({ topBar, contentPane, contentLabel: "사용자 확인", contentActionLabel: "승인 요청" });
}

/** Windows account sheet: signed out → Google sign-in; signed in → waiting for the owner's approval on the Mac, or connected. */
function AccountSection({ account, busy, signingIn, signIn, refresh, signOut }:
  { account?: ExecutorAccount; busy: boolean; signingIn: boolean; signIn(): void; refresh(): void; signOut(): void }) {
  const name = account?.displayName || "Google";
  if (!account?.signedIn) {
    return <section className="executor-account-state" aria-label="계정 상태" data-state="signed-out">
      <p className="executor-account-title">로그인 전</p>
      <p>Google 계정으로 로그인하면 Mac·iPad와 같은 작업 공간의 기기가 됩니다.</p>
      <div className="executor-setting-actions">
        <button type="button" disabled={busy || signingIn} onClick={signIn}>{signingIn ? "브라우저에서 로그인 중…" : "Google 계정으로 로그인"}</button>
      </div>
      <p className="executor-hint">{signingIn ? "브라우저에서 Google 로그인을 마치면 이 창으로 돌아옵니다." : "시스템 브라우저가 열립니다. 비밀번호는 이 앱에 입력하지 않습니다."}</p>
    </section>;
  }
  if (!account.approved) {
    return <section className="executor-account-state" aria-label="계정 상태" data-state="pending-approval" aria-live="polite">
      <p className="executor-account-title">{name} · Mac 승인 대기</p>
      <p>Mac의 뽀미에서 <strong>나 › 기기 승인</strong>의 Windows 항목을 승인해 주세요. 승인되면 이 기기가 자동으로 연결됩니다.</p>
      <div className="executor-setting-actions">
        <button type="button" disabled={busy} onClick={refresh}>다시 확인</button>
        <button type="button" disabled={busy} onClick={signOut}>로그아웃</button>
      </div>
      <p className="executor-hint">승인 전에는 대화와 기록 키를 받지 못합니다. 15초마다 서버에 확인합니다.</p>
    </section>;
  }
  return <section className="executor-account-state" aria-label="계정 상태" data-state="connected">
    <p className="executor-account-title">{name} · 기기 등록됨</p>
    <p>{account.recordKey ? "Mac이 감싼 기록 키를 받았습니다." : "Mac이 켜져 있을 때 기록 키를 받습니다."}</p>
    <div className="executor-setting-actions">
      <button type="button" disabled={busy} onClick={signOut}>로그아웃</button>
    </div>
  </section>;
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
