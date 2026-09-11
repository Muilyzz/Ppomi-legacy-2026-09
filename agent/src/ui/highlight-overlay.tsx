// 스텝 증빙 오버레이. Evidence/박스를 props로만 받는다(라이브 AX·캡처·런타임 없음).
// 작업대 오케스트레이터가 나중에 조합한다.
import { useCallback, useEffect, useRef, useState } from "react";
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

/** Where the picture lands inside the frame under `object-fit: contain`, as fractions of the frame. */
export type ImageRect = {
  readonly left: number;
  readonly top: number;
  readonly width: number;
  readonly height: number;
};

export const FULL_FRAME: ImageRect = { left: 0, top: 0, width: 1, height: 1 };

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

/** Letterboxed picture rect for `object-fit: contain`; the whole frame when a size is unknown. */
export function containedImageRect(
  frameWidth: number,
  frameHeight: number,
  imageWidth: number,
  imageHeight: number,
): ImageRect {
  if (!(frameWidth > 0 && frameHeight > 0 && imageWidth > 0 && imageHeight > 0)) return FULL_FRAME;
  const scale = Math.min(frameWidth / imageWidth, frameHeight / imageHeight);
  const width = (imageWidth * scale) / frameWidth;
  const height = (imageHeight * scale) / frameHeight;
  return { left: (1 - width) / 2, top: (1 - height) / 2, width, height };
}

/** Box fractions of the picture → fractions of the frame the boxes are positioned in. */
export function placeBox(box: OverlayBox, rect: ImageRect): ImageRect {
  return {
    left: rect.left + box.x * rect.width,
    top: rect.top + box.y * rect.height,
    width: box.width * rect.width,
    height: box.height * rect.height,
  };
}

export function HighlightOverlay({ evidence, boxes, selectedBoxId, imageSrc, alt }: HighlightOverlayProps) {
  const path = evidenceScreenshot(evidence);
  const src = imageSrc && isStaticImageSrc(imageSrc) ? imageSrc
    : path && isStaticImageSrc(path) ? path : undefined;
  const frameRef = useRef<HTMLDivElement>(null);
  const imageRef = useRef<HTMLImageElement>(null);
  const [imageRect, setImageRect] = useState<ImageRect>(FULL_FRAME);
  const [measured, setMeasured] = useState(false);

  const measure = useCallback(() => {
    const frame = frameRef.current;
    const image = imageRef.current;
    if (!frame || !image || image.naturalWidth === 0 || image.naturalHeight === 0) return;
    setImageRect(containedImageRect(frame.clientWidth, frame.clientHeight, image.naturalWidth, image.naturalHeight));
    setMeasured(true);
  }, []);

  useEffect(() => {
    setMeasured(false);
    setImageRect(FULL_FRAME);
    if (!src) return;
    measure(); // A cached picture may be complete before onLoad.
    const frame = frameRef.current;
    if (!frame || typeof ResizeObserver === "undefined") return;
    const observer = new ResizeObserver(measure);
    observer.observe(frame);
    return () => observer.disconnect();
  }, [src, measure]);

  if (!path) {
    return <div className="highlight-overlay" data-empty="true" hidden />;
  }

  const shown = visibleOverlayBoxes(boxes);
  const label = alt ?? "스텝 증빙";
  const rect = src ? imageRect : FULL_FRAME;

  return <figure className="highlight-overlay" data-empty="false">
    <div ref={frameRef} className="highlight-overlay-frame">
      {src
        ? <img key={src} ref={imageRef} src={src} alt={label} onLoad={measure} />
        : <div className="highlight-overlay-placeholder" role="img" aria-label={label}>화면</div>}
      {shown.length > 0 && <ol className="highlight-overlay-boxes" data-measured={!src || measured}>
        {shown.map(box => {
          const placed = placeBox(box, rect);
          return <li key={box.id} className="highlight-overlay-box"
            data-box-id={box.id} data-selected={box.id === selectedBoxId}
            style={{ left: pct(placed.left), top: pct(placed.top), width: pct(placed.width), height: pct(placed.height) }}>
            {box.label && <span className="highlight-overlay-box-label">{box.label}</span>}
          </li>;
        })}
      </ol>}
    </div>
    <figcaption className="highlight-overlay-caption">{path}</figcaption>
  </figure>;
}

function pct(value: number): string {
  return `${Math.round(value * 100000) / 1000}%`;
}
