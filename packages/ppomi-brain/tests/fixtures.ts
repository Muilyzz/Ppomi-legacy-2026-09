import { allowGrant, denyGrant, type PathGrant, type SessionIdentity } from "../src/grant.ts";
import type { PathDefinition } from "../src/path.ts";
import type {
  AccountSession,
  BodyRunInput,
  BodyRunResult,
  BodyRuntime,
  Memory,
  MemoryEvent,
  PathCatalog,
  PathLoader,
} from "../src/ports.ts";

export const identity: SessionIdentity = {
  ownerId: "owner-1",
  orgId: "org-family",
  seatId: "seat-1",
};

export const lookupPath: PathDefinition = {
  id: "path-balance",
  title: "잔액 조회",
  intents: ["잔액", "balance"],
  requiredEffects: ["lookup"],
  requiredSurfaces: ["app"],
  steps: [{ id: "read-balance", title: "잔액 읽기", effect: "lookup" }],
};

export const payPath: PathDefinition = {
  id: "path-pay",
  title: "공과금 납부 준비",
  intents: ["납부", "결제", "pay"],
  requiredEffects: ["lookup", "input"],
  requiredSurfaces: ["app"],
  steps: [
    { id: "read-bill", title: "고지서 확인", effect: "lookup" },
    { id: "fill-amount", title: "금액 입력", effect: "input" },
    { id: "submit-pay", title: "결제하기", effect: "financial_submit" },
  ],
};

export class FixedPaths implements PathCatalog, PathLoader {
  private readonly paths: readonly PathDefinition[];

  constructor(paths: readonly PathDefinition[]) {
    this.paths = paths;
  }

  list(): readonly PathDefinition[] {
    return this.paths;
  }

  load(id: string): PathDefinition | null {
    return this.paths.find(path => path.id === id) ?? null;
  }
}

export class MockSession implements AccountSession {
  private readonly who: SessionIdentity | null;
  private readonly decide: (path: PathDefinition) => ReturnType<AccountSession["grantFor"]>;

  constructor(
    who: SessionIdentity | null,
    decide: (path: PathDefinition) => ReturnType<AccountSession["grantFor"]>,
  ) {
    this.who = who;
    this.decide = decide;
  }

  current(): SessionIdentity | null {
    return this.who;
  }

  grantFor(path: PathDefinition, session: SessionIdentity) {
    if (this.who === null) return denyGrant("no account session");
    if (session.ownerId !== this.who.ownerId) return denyGrant("session mismatch");
    return this.decide(path);
  }
}

export class MockBody implements BodyRuntime {
  readonly calls: BodyRunInput[] = [];
  private readonly impl: (input: BodyRunInput) => BodyRunResult;

  constructor(impl: (input: BodyRunInput) => BodyRunResult) {
    this.impl = impl;
  }

  run(input: BodyRunInput): BodyRunResult {
    this.calls.push(input);
    return this.impl(input);
  }
}

export class MemoryLog implements Memory {
  readonly events: MemoryEvent[] = [];

  record(event: MemoryEvent): void {
    this.events.push(event);
  }
}

export function narrowGrant(path: PathDefinition, who: SessionIdentity = identity): PathGrant {
  return {
    pathId: path.id,
    ownerId: who.ownerId,
    effects: path.requiredEffects.filter(effect => effect !== "financial_submit"),
    surfaces: path.requiredSurfaces,
    ...(who.orgId !== undefined ? { orgId: who.orgId } : {}),
    ...(who.seatId !== undefined ? { seatId: who.seatId } : {}),
  };
}

export function sessionThatGrants(path: PathDefinition, who: SessionIdentity = identity): MockSession {
  return new MockSession(who, candidate => {
    if (candidate.id !== path.id) return denyGrant(`no grant for ${candidate.id}`);
    return allowGrant(narrowGrant(candidate, who));
  });
}

export function honestBody(): MockBody {
  return new MockBody(({ path, grant }) => {
    const steps = [];
    for (const step of path.steps) {
      if (step.effect === "financial_submit") {
        steps.push({
          stepId: step.id,
          effect: step.effect,
          status: "needs_human" as const,
          note: "confirm_payment handoff; financial_submit is not granted",
        });
        return { status: "stopped", stopReason: "needs_human", steps };
      }
      if (!grant.effects.includes(step.effect)) {
        steps.push({
          stepId: step.id,
          effect: step.effect,
          status: "grant_denied" as const,
          note: `ungranted ${step.effect}`,
        });
        return { status: "stopped", stopReason: "grant_denied", steps };
      }
      steps.push({
        stepId: step.id,
        effect: step.effect,
        status: "ok" as const,
        note: `${step.id} ok`,
      });
    }
    return { status: "completed", stopReason: null, steps };
  });
}
