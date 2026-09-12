// 픽스처 페이지. 런타임 코어가 방출한 StepResult 를 「스텝 기록」 패널이 그린다(emit → 뷰). 라이브 실행·캡처 없음.
import { useEffect, useState } from "react";
import type { StepResult } from "../../../packages/ppomi-body/src/step-result";
import { runFixturePlaybook, type FixtureSurface } from "./step-record-fixture-run";
import { StepRecordPanel } from "./step-record-panel";

export function StepRecordPreview({ surface = "os" }: { surface?: FixtureSurface }) {
  const [steps, setSteps] = useState<readonly StepResult[]>([]);

  useEffect(() => {
    let cancelled = false;
    setSteps([]);
    void runFixturePlaybook(surface).then(rows => { if (!cancelled) setSteps(rows); });
    return () => { cancelled = true; };
  }, [surface]);

  return <StepRecordPanel steps={steps} />;
}
