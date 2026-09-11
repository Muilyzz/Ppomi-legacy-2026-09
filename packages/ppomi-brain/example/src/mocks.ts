import type {
  AccountPort,
  BodyKind,
  BodyPort,
  BodyRunResult,
  Grant,
  MemoryPort,
  MemoryRecord,
  PathDefinition,
  PathPort,
} from "./ports.ts";

export const samplePaths: readonly PathDefinition[] = [
  {
    id: "sample-browse",
    title: "Open a public page and read the title",
    bodyKind: "macos",
    grant: "ui.read",
    financialSubmit: false,
    steps: [
      { id: "open", kind: "open", title: "Open the public page" },
      { id: "read-title", kind: "read", title: "Read the document title" },
    ],
  },
  {
    id: "joint-certificate-prepare",
    title: "Prepare a business joint-certificate issuance (no submit)",
    bodyKind: "windows",
    grant: "ui.control",
    financialSubmit: "human",
    steps: [
      { id: "focus-issuer", kind: "focus", title: "Focus the issuer window", target: "인증서 발급" },
      { id: "read-purpose", kind: "read", title: "Confirm purpose copy" },
      { id: "human-identity", kind: "human", title: "Identity check is the person" },
      { id: "pay-certificate", kind: "payment", title: "Payment — no auto click", target: "결제하기" },
      { id: "submit-application", kind: "submit", title: "Submit — no auto click", target: "제출" },
    ],
  },
];

export class MockPath implements PathPort {
  private readonly paths: readonly PathDefinition[];

  constructor(paths: readonly PathDefinition[] = samplePaths) {
    this.paths = paths;
  }

  select(intent: string): PathDefinition | null {
    const key = intent.trim().toLowerCase();
    if (key.length === 0) return null;
    return this.paths.find(path =>
      path.id === key
      || path.title.toLowerCase().includes(key)
      || (key.includes("cert") && path.id.includes("certificate"))
      || (key.includes("browse") && path.id.includes("browse")),
    ) ?? null;
  }
}

export class MockAccount implements AccountPort {
  private readonly grants: readonly Grant[];

  constructor(grants: readonly Grant[] = ["ui.read", "ui.control"]) {
    this.grants = grants;
  }

  hasGrant(grant: Grant): boolean {
    return this.grants.includes(grant);
  }
}

export class MockBody implements BodyPort {
  readonly kind: BodyKind = "mock";

  async run(path: PathDefinition): Promise<BodyRunResult> {
    const steps = path.steps.map(step => {
      switch (step.kind) {
        case "human":
          return { stepId: step.id, outcome: "skipped_human" as const, note: "HITL — mock does not act" };
        case "payment":
        case "submit":
          return { stepId: step.id, outcome: "blocked_submit" as const, note: `${step.kind} stays with the person` };
        case "open":
        case "focus":
        case "click":
        case "type":
        case "read":
          return { stepId: step.id, outcome: "ok" as const, note: `mock ${step.kind}` };
        default:
          return { stepId: step.id, outcome: "failed" as const, note: `unhandled kind ${step.kind}` };
      }
    });
    const stopped = steps.some(step => step.outcome === "failed");
    return { body: this.kind, status: stopped ? "stopped" : "completed", steps };
  }
}

export class InMemoryLog implements MemoryPort {
  private readonly records: MemoryRecord[] = [];

  remember(record: MemoryRecord): void {
    this.records.push(record);
  }

  list(): readonly MemoryRecord[] {
    return this.records;
  }
}
