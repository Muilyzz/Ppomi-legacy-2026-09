// 작업대 뼈대: 작업 공간(대화 · 제어) 또는 기록 페이지, 그리고 사람 차례일 때만 차례 띠. Mac(AppKit)·Android(Compose)가 같은 트리를
// 네이티브로 만들고, 여기서는 DOM으로 드러내 스토리북에서 검토한다. 서브트리는 주입, 스타일은 workbench.css. 요구 장부: docs/ui-tree.md.
import type { CSSProperties, ReactNode } from "react";

export type WorkbenchProps = {
  conversation: ReactNode;
  /** 제어 열: 머리띠 + 자리(대상 창이 앉는 빈 사각형). */
  control: ReactNode;
  /** 차례 띠: 질문 한 줄 + 버튼. 사람 차례일 때만 있다. */
  turn?: ReactNode;
  /** 대상 창 폭(px) = 제어 열 폭. 없으면 최소 폭. */
  targetWidth?: number;
  /** 기록 페이지: 있으면 작업 공간을 통째로 대체한다. */
  records?: ReactNode;
};

export function Workbench(p: WorkbenchProps) {
  return <div className="workbench" style={p.targetWidth ? { "--target": `${p.targetWidth}px` } as CSSProperties : undefined}>
    {p.records !== undefined
      ? <section className="records-page" aria-label="기록">{p.records}</section>
      : <div className="workspace">
          <section className="conversation" aria-label="대화">{p.conversation}</section>
          <section className="control" aria-label="제어">{p.control}</section>
        </div>}
    {p.turn !== undefined && <footer className="turn" aria-label="사람 차례">{p.turn}</footer>}
  </div>;
}

/** 제어 머리띠 한 줄: 대상 선택기(select·button 주입) · 동작(기록). */
export function ControlHeader({ target, actions }: { target: ReactNode; actions?: ReactNode }) {
  return <div className="control-header">{target}{actions}</div>;
}

/** 제어 자리. 차례 = 잉크 테두리, 그 외 테두리 없음. 비어 있으면 한 줄(children). */
export function ControlSlot({ turn, children }: { turn?: boolean; children?: ReactNode }) {
  return <div className={"control-slot" + (turn ? " turn" : "")}>{children}</div>;
}

/** 기록 페이지 머리띠: 대화로 돌아가기 + 탭(children). */
export function RecordsHeader({ onBack, children }: { onBack: () => void; children: ReactNode }) {
  return <div className="records-header">
    <button className="text" aria-label="대화로 돌아가기" onClick={onBack}>← 대화</button>
    {children}
  </div>;
}
