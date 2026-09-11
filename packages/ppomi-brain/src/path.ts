import type { ActionEffect, ExecutionSurface } from "./grant.ts";

/** Catalog row. Content lives in ppomi-path (or today's playbook / Catalog JSON). */
export interface PathSummary {
  readonly id: string;
  readonly title: string;
  readonly intents: readonly string[];
  readonly requiredEffects: readonly ActionEffect[];
  readonly requiredSurfaces: readonly ExecutionSurface[];
}

export interface PathStep {
  readonly id: string;
  readonly title: string;
  readonly effect: ActionEffect;
}

export interface PathDefinition extends PathSummary {
  readonly steps: readonly PathStep[];
}

export interface RunIntent {
  readonly text: string;
  readonly surface?: ExecutionSurface;
}

export function choosePath(
  catalog: readonly PathSummary[],
  intent: RunIntent,
): PathSummary | null {
  const text = intent.text.trim().toLowerCase();
  if (text.length === 0) return null;

  for (const path of catalog) {
    if (intent.surface !== undefined && !path.requiredSurfaces.includes(intent.surface)) {
      continue;
    }
    const hit = path.intents.some(candidate => {
      const needle = candidate.toLowerCase();
      return text.includes(needle) || needle.includes(text);
    });
    if (hit) return path;
  }
  return null;
}

/** Effects the agent may be granted. Financial final submit is never in this list. */
export function grantableEffects(
  effects: readonly ActionEffect[],
): readonly ActionEffect[] {
  return effects.filter(effect => effect !== "financial_submit");
}
