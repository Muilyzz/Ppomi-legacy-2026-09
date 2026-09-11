import { grantableEffects, type PathDefinition } from "./path.ts";

/**
 * MZZ-38 action effects. `financial_submit` is never issued to the agent.
 * `confirm_payment` is a human handoff, not an auto-submit unlock.
 */
export type ActionEffect = "lookup" | "save" | "input" | "transmit" | "financial_submit";

export type ExecutionSurface = "device" | "app" | "web" | "parallels-guest";

export interface SessionIdentity {
  readonly ownerId: string;
  readonly orgId?: string;
  readonly seatId?: string;
}

export interface PathGrant {
  readonly pathId: string;
  readonly ownerId: string;
  readonly orgId?: string;
  readonly seatId?: string;
  readonly effects: readonly ActionEffect[];
  readonly surfaces: readonly ExecutionSurface[];
}

export type GrantDecision =
  | { readonly allowed: true; readonly grant: PathGrant }
  | { readonly allowed: false; readonly reason: string };

export function denyGrant(reason: string): GrantDecision {
  return { allowed: false, reason };
}

export function allowGrant(grant: PathGrant): GrantDecision {
  return { allowed: true, grant };
}

/**
 * Brain-side grant check. Session may return a decision; this still refuses
 * `financial_submit`, path/owner mismatch, and missing required effects/surfaces.
 */
export function inspectGrant(
  path: PathDefinition,
  identity: SessionIdentity,
  decision: GrantDecision,
): GrantDecision {
  if (!decision.allowed) return decision;

  const { grant } = decision;
  if (grant.pathId !== path.id) {
    return denyGrant(`grant pathId ${grant.pathId} !== ${path.id}`);
  }
  if (grant.ownerId !== identity.ownerId) {
    return denyGrant("grant owner does not match session");
  }
  if (grant.orgId !== identity.orgId) {
    return denyGrant("grant org does not match session");
  }
  if (grant.seatId !== identity.seatId) {
    return denyGrant("grant seat does not match session");
  }
  if (grant.effects.includes("financial_submit")) {
    return denyGrant("financial_submit is never issued to the agent");
  }

  const missingEffects = grantableEffects(path.requiredEffects).filter(
    effect => !grant.effects.includes(effect),
  );
  if (missingEffects.length > 0) {
    return denyGrant(`missing effects: ${missingEffects.join(", ")}`);
  }

  const missingSurfaces = path.requiredSurfaces.filter(
    surface => !grant.surfaces.includes(surface),
  );
  if (missingSurfaces.length > 0) {
    return denyGrant(`missing surfaces: ${missingSurfaces.join(", ")}`);
  }

  return decision;
}

export function describeEffect(effect: ActionEffect): string {
  switch (effect) {
    case "lookup":
      return "lookup";
    case "save":
      return "save";
    case "input":
      return "input";
    case "transmit":
      return "transmit";
    case "financial_submit":
      return "financial_submit";
    default: {
      const exhaustive: never = effect;
      return exhaustive;
    }
  }
}
