// 스텝 기록 타임라인. StepResult 를 props로만 받는다(라이브 런타임 없음).
// 선택만 onSelect(stepId)로 알린다. StepRecordPanel 이 조합한다.
import type {
  StepAttempt,
  StepDriver,
  StepResult,
  StepResultStatus,
  StepTarget,
} from "../../../packages/ppomi-body/src/step-result";

export type StepTimelineProps = {
  steps: readonly StepResult[];
  selectedStepId?: string;
  onSelect: (stepId: string) => void;
};

export function statusLabel(status: StepResultStatus): string {
  switch (status) {
    case "ok": return "성공";
    case "retryable": return "재시도";
    case "ambiguous": return "모호";
    case "protected": return "보호";
    case "needs_human": return "사람 차례";
    case "failed": return "실패";
    default: {
      const _never: never = status;
      return _never;
    }
  }
}

export function attemptLabel(attempt: StepAttempt): string {
  switch (attempt) {
    case "executed": return "실행";
    case "timeout": return "시간 초과";
    case "not_executed": return "미실행";
    default: {
      const _never: never = attempt;
      return _never;
    }
  }
}

/** Which ppomi-body driver produced the row. Family names only; no vendor or package names. */
export function driverLabel(driver: StepDriver): string {
  switch (driver) {
    case "page": return "웹 페이지";
    case "os-windows": return "Windows";
    case "os-macos": return "Mac";
    case "os-android": return "Android";
    case "phone": return "휴대폰";
    default: {
      const _never: never = driver;
      return _never;
    }
  }
}

export function targetLabel(target: StepTarget): string {
  switch (target.kind) {
    case "locator": return target.locator;
    case "url": return target.url;
    case "accessibility": return target.role ? `${target.name} (${target.role})` : target.name;
    case "none": return "—";
    default: {
      const _never: never = target;
      return _never;
    }
  }
}

export function StepTimeline({ steps, selectedStepId, onSelect }: StepTimelineProps) {
  return <ol className="step-timeline" aria-label="스텝 기록">
    {steps.map(step => {
      const selected = step.stepId === selectedStepId;
      return <li key={step.stepId}>
        <button type="button" className="step-card" data-status={step.status} data-step-id={step.stepId}
          aria-pressed={selected} onClick={() => onSelect(step.stepId)}>
          <span className="step-card-status">{statusLabel(step.status)}</span>
          <strong className="step-card-title">{step.action} · {step.stepId}</strong>
          <span className="step-card-meta">
            {driverLabel(step.driver)} · {attemptLabel(step.attempt)} · {targetLabel(step.target)}
            {step.code && <> · <code className="step-card-code">{step.code}</code></>}
          </span>
          <span className="step-card-summary">{step.observation.summary}</span>
          <span className="step-card-timing">{step.timingMs} ms</span>
        </button>
      </li>;
    })}
  </ol>;
}
