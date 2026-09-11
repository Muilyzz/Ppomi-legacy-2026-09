// 픽스처 페이지. 런타임이 방출한 StepResult 를 「스텝 기록」 패널이 그린다(emit → 뷰). 라이브 실행·캡처 없음.
import { useMemo } from "react";
import { runFixturePlaybook, type FixtureSurface } from "./step-record-fixture-run";
import { StepRecordPanel } from "./step-record-panel";

export function StepRecordPreview({ surface = "os" }: { surface?: FixtureSurface }) {
  const steps = useMemo(() => runFixturePlaybook(surface), [surface]);
  return <StepRecordPanel steps={steps} />;
}
