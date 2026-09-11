import type { PageStepKind, Permission, StepKind } from "./playbook.ts";

export interface PermissionGate {
  allows(permission: Permission): boolean;
}

export class FixedPermissionGate implements PermissionGate {
  private readonly granted: ReadonlySet<Permission>;

  constructor(granted: readonly Permission[]) {
    this.granted = new Set(granted);
  }

  allows(permission: Permission): boolean {
    return this.granted.has(permission);
  }
}

export function defaultPermission(kind: StepKind): Permission {
  switch (kind) {
    case "read":
      return "ui.read";
    case "focus":
    case "click":
    case "type":
    case "key":
      return "ui.control";
    default: {
      const exhaustive: never = kind;
      return exhaustive;
    }
  }
}

export function defaultPagePermission(kind: PageStepKind): Permission {
  switch (kind) {
    case "read":
    case "waitFor":
      return "ui.read";
    case "goto":
    case "click":
    case "fill":
      return "ui.control";
    default: {
      const exhaustive: never = kind;
      return exhaustive;
    }
  }
}
