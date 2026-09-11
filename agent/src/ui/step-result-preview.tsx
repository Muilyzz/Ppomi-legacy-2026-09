// 정적 JSON 픽스처 페이지. 작업대 기록 칸의 런타임 조합은 StepRecordPane.
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
