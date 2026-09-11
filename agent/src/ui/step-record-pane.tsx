// 작업대 기록 칸. Dummy 런타임 stepResults → StepTimeline. 선택 스텝이 증빙/박스가 있을 때만 HighlightOverlay.
import { useState } from "react";
import type { StepResult } from "../../../packages/playbook-runtime/src/step-result";
import { HighlightOverlay } from "./highlight-overlay";
import { runFixtureStepRecord } from "./step-record-run";
import { overlayFixture } from "./step-result-fixtures";
import { StepTimeline } from "./step-timeline";

const fixtureRun = runFixtureStepRecord();

export type StepRecordPaneProps = {
  steps?: readonly StepResult[];
  selectedStepId?: string;
  onSelect?: (stepId: string) => void;
};

export function StepRecordPane({
  steps = fixtureRun,
  selectedStepId,
  onSelect,
}: StepRecordPaneProps) {
  const initial = steps.find(step => step.evidence)?.stepId ?? steps[0]?.stepId;
  const [uncontrolled, setUncontrolled] = useState(initial);
  const selected = selectedStepId ?? uncontrolled;
  const select = onSelect ?? setUncontrolled;
  const step = steps.find(row => row.stepId === selected);
  const overlay = selected ? overlayFixture(selected) : undefined;

  return <div className="step-record-pane" aria-label="스텝 기록">
    <p className="step-record-pane-note">path / body 실행 기록. 픽스처 런타임. 라이브 AX·Playwright 없음.</p>
    <HighlightOverlay evidence={step?.evidence} boxes={overlay?.boxes}
      selectedBoxId={overlay?.selectedBoxId} imageSrc={overlay?.imageSrc} />
    <StepTimeline steps={steps} selectedStepId={selected} onSelect={select} />
  </div>;
}
