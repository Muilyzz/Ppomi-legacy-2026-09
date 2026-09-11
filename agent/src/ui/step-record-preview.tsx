// 픽스처 페이지. 런타임이 방출한 StepResult 를 「스텝 기록」 패널이 그린다(emit → 뷰). 라이브 실행·캡처 없음.
import { useMemo } from "react";
import { runFixturePlaybook } from "./step-record-fixture-run";
import { StepRecordPanel } from "./step-record-panel";

export function StepRecordPreview() {
  const steps = useMemo(() => runFixturePlaybook(), []);
  return <StepRecordPanel steps={steps} />;
}
