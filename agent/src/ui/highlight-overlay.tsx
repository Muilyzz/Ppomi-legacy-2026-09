// 스텝 증빙 오버레이. Evidence/박스를 props로만 받는다(라이브 AX·캡처·런타임 없음).
// 작업대 오케스트레이터가 나중에 조합한다.
import type { Evidence } from "../../../packages/playbook-runtime/src/step-result";

/** Session-only geometry for the selected step. Not a StepResult.target field. */
export type OverlayBox = {
  readonly id: string;
  readonly x: number;
  readonly y: number;
  readonly width: number;
  readonly height: number;
  readonly label?: string;
};

export type HighlightOverlayProps = {
  evidence?: Evidence;
  boxes?: readonly OverlayBox[];
  selectedBoxId?: string;
  /** Optional static image. File paths on evidence stay captions unless they are URLs. */
  imageSrc?: string;
  alt?: string;
};

export function evidenceScreenshot(evidence: Evidence | undefined): string | undefined {
  if (!evidence) return undefined;
  return evidence.screenshotAfter ?? evidence.screenshotBefore;
}

export function isStaticImageSrc(src: string): boolean {
  return /^(data:|blob:|https?:\/\/|\/)/.test(src);
}

export function visibleOverlayBoxes(boxes: readonly OverlayBox[] | undefined): OverlayBox[] {
  if (!boxes) return [];
  return boxes.filter(box =>
    Number.isFinite(box.x) && Number.isFinite(box.y)
    && Number.isFinite(box.width) && Number.isFinite(box.height)
    && box.width > 0 && box.height > 0 && box.id.length > 0);
}

export function HighlightOverlay({ evidence, boxes, selectedBoxId, imageSrc, alt }: HighlightOverlayProps) {
  const path = evidenceScreenshot(evidence);
  if (!path) {
    return <div className="highlight-overlay" data-empty="true" hidden />;
  }

  const src = imageSrc && isStaticImageSrc(imageSrc) ? imageSrc
    : isStaticImageSrc(path) ? path : undefined;
  const shown = visibleOverlayBoxes(boxes);
  const label = alt ?? "스텝 증빙";

  return <figure className="highlight-overlay" data-empty="false">
    <div className="highlight-overlay-frame">
      {src
        ? <img src={src} alt={label} />
        : <div className="highlight-overlay-placeholder" role="img" aria-label={label}>화면</div>}
      {shown.length > 0 && <ol className="highlight-overlay-boxes">
        {shown.map(box => <li key={box.id} className="highlight-overlay-box"
          data-box-id={box.id} data-selected={box.id === selectedBoxId}
          style={{ left: pct(box.x), top: pct(box.y), width: pct(box.width), height: pct(box.height) }}>
          {box.label && <span className="highlight-overlay-box-label">{box.label}</span>}
        </li>)}
      </ol>}
    </div>
    <figcaption className="highlight-overlay-caption">{path}</figcaption>
  </figure>;
}

function pct(value: number): string {
  return `${value * 100}%`;
}
