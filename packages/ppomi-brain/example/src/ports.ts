export type Grant = "ui.read" | "ui.control";
export type BodyKind = "mock" | "macos" | "windows";
export type FinancialSubmit = false | "human";

export interface PathStep {
  readonly id: string;
  readonly kind: string;
  readonly title: string;
  readonly target?: string;
}

export interface PathDefinition {
  readonly id: string;
  readonly title: string;
  readonly bodyKind: Exclude<BodyKind, "mock"> | "macos" | "windows";
  readonly grant: Grant;
  readonly financialSubmit: FinancialSubmit;
  readonly steps: readonly PathStep[];
}

export interface PathPort {
  select(intent: string): PathDefinition | null;
}

export interface AccountPort {
  hasGrant(grant: Grant): boolean;
}

export interface BodyStepResult {
  readonly stepId: string;
  readonly outcome: "ok" | "skipped_human" | "blocked_submit" | "failed";
  readonly note: string;
}

export interface BodyRunResult {
  readonly body: BodyKind;
  readonly status: "completed" | "stopped";
  readonly steps: readonly BodyStepResult[];
}

export interface BodyPort {
  readonly kind: BodyKind;
  run(path: PathDefinition): Promise<BodyRunResult>;
}

export interface MemoryRecord {
  readonly intent: string;
  readonly pathId: string;
  readonly body: BodyKind;
  readonly status: BodyRunResult["status"];
}

export interface MemoryPort {
  remember(record: MemoryRecord): void;
  list(): readonly MemoryRecord[];
}

export interface OrchestrateInput {
  readonly intent: string;
  readonly path: PathPort;
  readonly account: AccountPort;
  readonly body: BodyPort;
  readonly memory: MemoryPort;
}

export type OrchestrateStatus =
  | "completed"
  | "stopped"
  | "path_not_found"
  | "grant_denied";

export interface OrchestrateResult {
  readonly status: OrchestrateStatus;
  readonly pathId: string | null;
  readonly body: BodyKind;
  readonly note: string;
  readonly steps: readonly BodyStepResult[];
}
