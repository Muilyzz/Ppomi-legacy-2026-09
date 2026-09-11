// 작업대 기록 패널 「스텝 기록」. RunResult.stepResults 를 props로 받아 StepTimeline 과 HighlightOverlay 를 조합한다.
// 선택 상태는 이 패널이 갖는다. 라이브 런타임·드라이버·화면 캡처는 붙이지 않는다(오케스트레이터가 나중에 연결).
import { useId, useRef, useState, type KeyboardEvent } from "react";
import type { StepResult } from "../../../packages/playbook-runtime/src/step-result";
import { evidenceScreenshot, HighlightOverlay, type OverlayBox } from "./highlight-overlay";
import { StepTimeline } from "./step-timeline";

/** What the panel may show for one step's recorded screenshot: a picture the browser can load plus session boxes. */
export type StepScreenshot = {
  readonly src?: string;
  readonly boxes?: readonly OverlayBox[];
  readonly selectedBoxId?: string;
};

/** Turns recorded evidence into a picture. Consulted only for a step that has a screenshot on record. */
export type StepScreenshotResolver = (step: StepResult) => StepScreenshot | undefined;

export type StepRecordPanelProps = {
  steps: readonly StepResult[];
  screenshots?: StepScreenshotResolver;
  /** Initial choice. Without it: the first step with a screenshot on record, else the first step. */
  defaultSelectedStepId?: string;
  title?: string;
};

export type StepNavigationKey = "ArrowDown" | "ArrowUp" | "Home" | "End";

export function isStepNavigationKey(key: string): key is StepNavigationKey {
  return key === "ArrowDown" || key === "ArrowUp" || key === "Home" || key === "End";
}

/** Index to move to; arrows wrap at both ends. -1 when there is nothing to move to. */
export function nextStepIndex(current: number, key: StepNavigationKey, count: number): number {
  if (count <= 0) return -1;
  switch (key) {
    case "ArrowDown": return current < 0 ? 0 : (current + 1) % count;
    case "ArrowUp": return current < 0 ? count - 1 : (current - 1 + count) % count;
    case "Home": return 0;
    case "End": return count - 1;
    default: {
      const _never: never = key;
      return _never;
    }
  }
}

/** The chosen step while it still exists in `steps`; otherwise the first with a screenshot, else the first. */
export function selectedStep(
  steps: readonly StepResult[],
  chosenStepId: string | undefined,
): StepResult | undefined {
  return steps.find(step => step.stepId === chosenStepId)
    ?? steps.find(step => evidenceScreenshot(step.evidence) !== undefined)
    ?? steps[0];
}

export function StepRecordPanel({ steps, screenshots, defaultSelectedStepId, title = "스텝 기록" }: StepRecordPanelProps) {
  const [chosenStepId, setChosenStepId] = useState(defaultSelectedStepId);
  const timeline = useRef<HTMLDivElement>(null);
  const headingId = useId();
  const step = selectedStep(steps, chosenStepId);

  const focusStep = (stepId: string) => {
    for (const button of timeline.current?.querySelectorAll<HTMLButtonElement>("button[data-step-id]") ?? []) {
      if (button.dataset.stepId === stepId) { button.focus(); return; }
    }
  };

  const onKeyDown = (event: KeyboardEvent<HTMLDivElement>) => {
    if (!isStepNavigationKey(event.key)) return;
    const next = steps[nextStepIndex(step ? steps.indexOf(step) : -1, event.key, steps.length)];
    if (!next) return;
    event.preventDefault();
    setChosenStepId(next.stepId);
    focusStep(next.stepId);
  };

  const header = <header className="step-record-header">
    <h3 id={headingId} className="step-record-title">{title}</h3>
    {steps.length > 0 && <span className="step-record-count">{steps.length} 스텝</span>}
  </header>;

  if (steps.length === 0 || !step) {
    return <section className="step-record-panel" aria-labelledby={headingId} data-empty="true">
      {header}
      <p className="step-record-empty">기록된 스텝이 없습니다.</p>
    </section>;
  }

  const hasScreenshot = evidenceScreenshot(step.evidence) !== undefined;
  const shot = hasScreenshot ? screenshots?.(step) : undefined;

  return <section className="step-record-panel" aria-labelledby={headingId} data-empty="false">
    {header}
    {hasScreenshot
      ? <HighlightOverlay evidence={step.evidence} imageSrc={shot?.src} boxes={shot?.boxes}
          selectedBoxId={shot?.selectedBoxId} alt={`${step.stepId} 스텝 증빙`} />
      : <p className="step-record-no-evidence">선택한 스텝에는 증빙 화면이 없습니다.</p>}
    <div ref={timeline} className="step-record-timeline" onKeyDown={onKeyDown}>
      <StepTimeline steps={steps} selectedStepId={step.stepId} onSelect={setChosenStepId} />
    </div>
  </section>;
}
