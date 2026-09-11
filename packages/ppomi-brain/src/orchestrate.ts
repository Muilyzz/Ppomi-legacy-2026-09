import { inspectGrant, type PathGrant } from "./grant.ts";
import { choosePath, type RunIntent } from "./path.ts";
import type {
  BodyRunResult,
  BodyStepResult,
  BrainPorts,
  Memory,
} from "./ports.ts";

/**
 * ppomi-brain: orchestration, not chat UI (ppomi-chat) and not Clerk.
 * Path catalog = ppomi-path; body = ppomi-body / playbook-runtime; account = ppomi-account.
 */
export type OrchestrationStatus =
  | "completed"
  | "path_not_found"
  | "grant_denied"
  | "needs_human"
  | "protected"
  | "failed";

export interface OrchestrationResult {
  readonly status: OrchestrationStatus;
  readonly pathId: string | null;
  readonly grant: PathGrant | null;
  readonly body: BodyRunResult | null;
  readonly note: string;
}

export class PpomiBrain {
  private readonly ports: BrainPorts;

  constructor(ports: BrainPorts) {
    this.ports = ports;
  }

  run(intent: RunIntent): Promise<OrchestrationResult> {
    return orchestrate(this.ports, intent);
  }
}

export async function orchestrate(
  ports: BrainPorts,
  intent: RunIntent,
): Promise<OrchestrationResult> {
  const identity = await ports.session.current();
  if (identity === null) {
    return finish(ports.memory, {
      status: "grant_denied",
      pathId: null,
      grant: null,
      body: null,
      note: "no account session",
    });
  }

  const catalog = await ports.paths.list();
  const summary = choosePath(catalog, intent);
  if (summary === null) {
    return finish(ports.memory, {
      status: "path_not_found",
      pathId: null,
      grant: null,
      body: null,
      note: "no path matched the intent",
    });
  }

  const path = await ports.paths.load(summary.id);
  if (path === null) {
    return finish(ports.memory, {
      status: "path_not_found",
      pathId: summary.id,
      grant: null,
      body: null,
      note: `path ${summary.id} missing from loader`,
    });
  }

  const issued = await ports.session.grantFor(path, identity);
  const decision = inspectGrant(path, identity, issued);
  if (!decision.allowed) {
    return finish(ports.memory, {
      status: "grant_denied",
      pathId: path.id,
      grant: null,
      body: null,
      note: decision.reason,
    });
  }

  const body = await ports.body.run({ path, grant: decision.grant });
  const violation = bodyViolatedGrant(body);
  if (violation !== null) {
    return finish(ports.memory, {
      status: "failed",
      pathId: path.id,
      grant: decision.grant,
      body,
      note: violation,
    });
  }

  return finish(ports.memory, {
    status: orchestrationStatus(body),
    pathId: path.id,
    grant: decision.grant,
    body,
    note: bodyNote(body),
  });
}

function bodyViolatedGrant(body: BodyRunResult): string | null {
  for (const step of body.steps) {
    if (step.effect === "financial_submit" && step.status === "ok") {
      return "body claimed financial_submit success; brain will not accept it";
    }
  }
  return null;
}

function orchestrationStatus(body: BodyRunResult): OrchestrationStatus {
  if (body.status === "completed") return "completed";
  const reason = body.stopReason;
  if (reason === null) return "failed";
  switch (reason) {
    case "needs_human":
      return "needs_human";
    case "protected":
      return "protected";
    case "grant_denied":
      return "grant_denied";
    case "failed":
      return "failed";
    default: {
      const exhaustive: never = reason;
      return exhaustive;
    }
  }
}

function bodyNote(body: BodyRunResult): string {
  const last: BodyStepResult | undefined = body.steps.at(-1);
  if (last === undefined) return "body returned no steps";
  return last.note;
}

async function finish(
  memory: Memory | undefined,
  result: OrchestrationResult,
): Promise<OrchestrationResult> {
  if (memory !== undefined) {
    await memory.record({
      kind: "run",
      pathId: result.pathId ?? "(none)",
      status: result.status,
      note: result.note,
    });
  }
  return result;
}
