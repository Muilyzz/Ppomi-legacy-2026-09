// 픽스처 페이지. 타임라인과 오버레이를 나란히 보여 스토리/검사만 한다.
// 라이브 작업대 제어 자리·캡처·런타임 방출은 붙이지 않는다. 오케스트레이터가 나중에 조합한다.
import { useState } from "react";
import { HighlightOverlay } from "./highlight-overlay";
import { overlayFixture, fixtureSteps } from "./step-result-fixtures";
import { StepTimeline } from "./step-timeline";

export function StepResultPreview() {
  const initial = fixtureSteps.find(step => step.evidence)?.stepId ?? fixtureSteps[0]?.stepId;
  const [selectedStepId, setSelectedStepId] = useState(initial);
  const step = fixtureSteps.find(row => row.stepId === selectedStepId);
  const overlay = selectedStepId ? overlayFixture(selectedStepId) : undefined;

  return <div className="step-result-preview">
    <HighlightOverlay evidence={step?.evidence} boxes={overlay?.boxes}
      selectedBoxId={overlay?.selectedBoxId} imageSrc={overlay?.imageSrc} />
    <StepTimeline steps={fixtureSteps} selectedStepId={selectedStepId} onSelect={setSelectedStepId} />
  </div>;
}
