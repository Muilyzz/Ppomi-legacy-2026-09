import type { Playbook, PlaybookStep, StepKind, StepRequirement } from "../../playbook-runtime/src/index.ts";

export type KrCertStepKind = "focus" | "click" | "type" | "read" | "human" | "payment" | "submit";

export interface KrCertStep {
  readonly id: string;
  readonly title: string;
  readonly kind: KrCertStepKind;
  readonly target?: string;
  readonly text?: string;
  readonly require?: StepRequirement;
}

export interface KrCertPlaybook {
  readonly id: "playbook-kr-cert";
  readonly version: string;
  readonly title: string;
  readonly steps: readonly KrCertStep[];
}

/**
 * Fixture scenario only. No issuer auto-select, secrets, or device-approval gate.
 * `payment` / `submit` stay in the content so fail-closed can be tested.
 */
export const krCertPlaybook: KrCertPlaybook = {
  id: "playbook-kr-cert",
  version: "0.1.0",
  title: "사업자 공동인증서 발급 준비",
  steps: [
    {
      id: "focus-issuer-window",
      title: "인증서 발급 창에 초점",
      kind: "focus",
      target: "인증서 발급",
    },
    {
      id: "read-purpose",
      title: "용도 안내 확인",
      kind: "read",
      require: { screen: ["인증서 발급", "용도"] },
    },
    {
      id: "open-next",
      title: "다음 화면",
      kind: "click",
      target: "다음",
    },
    {
      id: "fill-business-kind",
      title: "사업자 구분 준비 (비밀·주민번호 아님)",
      kind: "type",
      target: "사업자 구분",
      text: "개인사업자",
    },
    {
      id: "read-fee",
      title: "수수료 표시 확인",
      kind: "read",
      require: { screen: ["수수료"] },
    },
    {
      id: "human-identity",
      title: "본인 확인은 당사자",
      kind: "human",
    },
    {
      id: "pay-certificate",
      title: "결제 — 자동 클릭 금지",
      kind: "payment",
      target: "결제하기",
    },
    {
      id: "submit-application",
      title: "제출 — 자동 클릭 금지",
      kind: "submit",
      target: "제출",
    },
  ],
};

export function krCertPreparePlaybook(): Playbook {
  return { id: "playbook-kr-cert-prepare", steps: mapUntilBlocked(krCertPlaybook.steps) };
}

export function krCertRuntimePlaybook(): Playbook {
  return { id: krCertPlaybook.id, steps: mapAll(krCertPlaybook.steps) };
}

function mapUntilBlocked(steps: readonly KrCertStep[]): PlaybookStep[] {
  const out: PlaybookStep[] = [];
  for (const step of steps) {
    if (step.kind === "human" || step.kind === "payment" || step.kind === "submit") break;
    const mapped = mapStep(step);
    if (mapped !== null) out.push(mapped);
  }
  return out;
}

function mapAll(steps: readonly KrCertStep[]): PlaybookStep[] {
  const out: PlaybookStep[] = [];
  for (const step of steps) {
    const mapped = mapStep(step);
    if (mapped !== null) out.push(mapped);
  }
  return out;
}

function mapStep(step: KrCertStep): PlaybookStep | null {
  switch (step.kind) {
    case "focus":
    case "click":
    case "type":
    case "read":
      return runtimeStep(step, step.kind);
    case "human":
      return null;
    case "payment":
    case "submit":
      if (step.target === undefined || step.target.length === 0) {
        throw new Error(`playbook-kr-cert ${step.kind} step ${step.id} needs a target`);
      }
      return runtimeStep(step, "click");
    default: {
      const exhaustive: never = step.kind;
      throw new Error(`unhandled kr-cert step kind: ${String(exhaustive)}`);
    }
  }
}

function runtimeStep(step: KrCertStep, kind: StepKind): PlaybookStep {
  const mapped: PlaybookStep = { id: step.id, kind };
  return {
    ...mapped,
    ...(step.target !== undefined ? { target: step.target } : {}),
    ...(step.text !== undefined ? { text: step.text } : {}),
    ...(step.require !== undefined ? { require: step.require } : {}),
  };
}
