// 스텝 기록 타임라인. StepResult를 props로만 받는다(라이브 런타임 없음).
// 선택만 onSelect(stepId)로 알린다. 작업대 오케스트레이터가 나중에 조합한다.
import type {
  StepAdapter,
  StepAttempt,
  StepResult,
  StepResultStatus,
  StepTarget,
} from "../../../packages/playbook-runtime/src/step-result";

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
    case "needs_human": return "사람";
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

export function adapterLabel(adapter: StepAdapter): string {
  switch (adapter) {
    case "page": return "page";
    case "os-windows": return "os-windows";
    case "os-macos": return "os-macos";
    case "phone": return "phone";
    default: {
      const _never: never = adapter;
      return _never;
    }
  }
}

export function targetLabel(target: StepTarget): string {
  switch (target.kind) {
    case "locator": return target.locator;
    case "url": return target.url;
    case "accessibility": return target.name;
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
          <span className="step-card-meta">{adapterLabel(step.adapter)} · {attemptLabel(step.attempt)} · {targetLabel(step.target)}</span>
          <span className="step-card-summary">{step.observation.summary}</span>
          <span className="step-card-timing num">{step.timingMs} ms</span>
        </button>
      </li>;
    })}
  </ol>;
}
