import type { Permission, StepKind } from "./playbook.ts";

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
      return "ui.control";
    default: {
      const exhaustive: never = kind;
      return exhaustive;
    }
  }
}
