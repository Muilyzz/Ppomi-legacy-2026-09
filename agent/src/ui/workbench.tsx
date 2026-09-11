// 공통 작업대: 상단 바 · 대화 · 콘텐츠의 세 영역을 유지한다.
// 넓을 때 콘텐츠는 왼쪽, 대화는 오른쪽. 좁을 때 콘텐츠만 요청에 따라 시트로 연다.
import { useEffect, useId, useLayoutEffect, useRef, useState, type KeyboardEvent, type ReactNode } from "react";

export type WorkbenchProps = {
  /** 계정과 앱 전체 동작. 좁은 화면의 기록 진입점은 프레임이 덧붙인다. */
  topBar: ReactNode;
  /** 글·통화·입력. 콘텐츠나 화면 폭을 바꿔도 같은 자리에 마운트된다. */
  conversation: ReactNode;
  /** 기본은 기록. 필요할 때 상세·제어·승인을 같은 영역 안에 둔다. */
  contentPane?: ReactNode;
  contentLabel?: string;
  contentActionLabel?: string;
};

const focusable = (root: HTMLElement) => Array.from(root.querySelectorAll<HTMLElement>(
  'button, a[href], input, select, textarea, [tabindex]',
)).filter(element => element.tabIndex >= 0 && !element.matches(':disabled')
  && !element.closest('[inert]') && element.getClientRects().length > 0);

export function Workbench(p: WorkbenchProps) {
  const root = useRef<HTMLDivElement>(null);
  const content = useRef<HTMLElement>(null);
  const closeButton = useRef<HTMLButtonElement>(null);
  const returnFocus = useRef<HTMLElement | null>(null);
  const [compact, setCompact] = useState(true);
  const [contentOpen, setContentOpen] = useState(false);
  const contentId = useId();
  const label = p.contentLabel ?? "기록 및 작업";
  const hasContent = p.contentPane !== undefined && p.contentPane !== null && p.contentPane !== false;
  const sheetOpen = hasContent && compact && contentOpen;

  useEffect(() => { if (!hasContent) setContentOpen(false); }, [hasContent]);

  useLayoutEffect(() => {
    const element = root.current;
    if (!element) return;
    const resize = () => {
      const next = element.getBoundingClientRect().width < 600;
      setCompact(next);
      if (!next) setContentOpen(false); // Returning to compact starts with chat alone.
    };
    resize();
    const observer = new ResizeObserver(resize);
    observer.observe(element);
    return () => observer.disconnect();
  }, []);

  useEffect(() => {
    if (!sheetOpen) return;
    const previous = returnFocus.current ?? (document.activeElement instanceof HTMLElement ? document.activeElement : null);
    closeButton.current?.focus({ preventScroll: true });
    return () => {
      const current = document.activeElement;
      // Expanding the frame keeps focus in a still-visible content control.
      if (current instanceof HTMLElement && content.current?.contains(current)
        && current.getClientRects().length && !current.closest('[inert]')) return;
      const target = previous?.isConnected && previous.getClientRects().length && !previous.closest('[inert]')
        ? previous : root.current ? focusable(root.current)[0] : null;
      target?.focus({ preventScroll: true });
    };
  }, [sheetOpen]);

  const sheetKeyDown = (event: KeyboardEvent<HTMLElement>) => {
    if (!sheetOpen || !content.current) return;
    if (event.key === "Escape") { event.preventDefault(); event.stopPropagation(); setContentOpen(false); }
    if (event.key !== "Tab") return;
    const items = focusable(content.current);
    const first = items[0], last = items.at(-1);
    if (!first) { event.preventDefault(); content.current.focus(); return; }
    if (event.shiftKey && (document.activeElement === first || !items.includes(document.activeElement as HTMLElement))) {
      event.preventDefault(); last?.focus();
    } else if (!event.shiftKey && (document.activeElement === last || !items.includes(document.activeElement as HTMLElement))) {
      event.preventDefault(); first.focus();
    }
  };

  return <div ref={root} className="workbench" data-compact={compact} data-has-content={hasContent}>
    <header className="workbench-top-bar" aria-label="앱" inert={sheetOpen || undefined}>
      <div className="workbench-top-bar-content">{p.topBar}</div>
      {hasContent && <button className="workbench-content-toggle" aria-controls={contentId} aria-expanded={sheetOpen}
        aria-haspopup="dialog" onClick={event => { returnFocus.current = event.currentTarget; setContentOpen(true); }}>{p.contentActionLabel ?? "기록 보기"}</button>}
    </header>
    <section className="workbench-chat" aria-label="대화" inert={sheetOpen || undefined}>{p.conversation}</section>
    <section ref={content} id={contentId} className="workbench-content" aria-label={label}
      hidden={!hasContent || compact && !contentOpen} inert={!hasContent || compact && !contentOpen || undefined}
      role={sheetOpen ? "dialog" : undefined} aria-modal={sheetOpen || undefined} tabIndex={-1} onKeyDown={sheetKeyDown}>
      <div className="workbench-sheet-backdrop" aria-hidden="true" onClick={() => setContentOpen(false)} />
      <div className="workbench-content-panel">
        <div className="workbench-sheet-header">
          <h2>{label}</h2>
          <button ref={closeButton} className="workbench-sheet-close" aria-label={`${label} 닫기`}
            onClick={() => setContentOpen(false)}>닫기</button>
        </div>
        {p.contentPane}
      </div>
    </section>
  </div>;
}

/** 콘텐츠의 제어 머리띠: 대상과 해당 작업의 동작. */
export function ControlHeader({ target, actions }: { target: ReactNode; actions?: ReactNode }) {
  return <div className="control-header">{target}{actions}</div>;
}

/** 제어 자리. 차례 = 잉크 테두리, 그 외 테두리 없음. 비어 있으면 한 줄(children). */
export function ControlSlot({ turn, children }: { turn?: boolean; children?: ReactNode }) {
  return <div className={"control-slot" + (turn ? " turn" : "")}>{children}</div>;
}

/** 콘텐츠의 기록 머리띠. 대화는 유지하므로 돌아가기 동작이 없다. */
export function RecordsHeader({ children }: { children: ReactNode }) {
  return <div className="records-header">{children}</div>;
}
