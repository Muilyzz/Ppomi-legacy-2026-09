import type { OrchestrateInput, OrchestrateResult } from "./ports.ts";

export async function orchestrate(input: OrchestrateInput): Promise<OrchestrateResult> {
  const path = input.path.select(input.intent);
  if (path === null) {
    return {
      status: "path_not_found",
      pathId: null,
      body: input.body.kind,
      note: `no path for intent: ${input.intent}`,
      steps: [],
    };
  }
  if (!input.account.hasGrant(path.grant)) {
    return {
      status: "grant_denied",
      pathId: path.id,
      body: input.body.kind,
      note: `missing grant ${path.grant}`,
      steps: [],
    };
  }
  const run = await input.body.run(path);
  input.memory.remember({
    intent: input.intent,
    pathId: path.id,
    body: run.body,
    status: run.status,
  });
  return {
    status: run.status,
    pathId: path.id,
    body: run.body,
    note: run.status === "completed" ? "path selected, grant ok, body ran" : "body stopped",
    steps: run.steps,
  };
}
