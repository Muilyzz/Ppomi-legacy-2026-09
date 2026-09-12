import type { PathDocument, PathStep, PathStepKind } from "./schema.ts";

/** Steps the agent must not run. MZZ-38: financial final submit stays with the person. */
export function isHandoffStep(step: PathStep): boolean {
  switch (step.kind) {
    case "human":
    case "payment":
    case "submit":
      return true;
    case "focus":
    case "click":
    case "type":
    case "read":
    case "key":
    case "goto":
    case "fill":
    case "waitFor":
      return false;
    default: {
      const exhaustive: never = step.kind;
      return exhaustive;
    }
  }
}

/** PageSurface can run these. OS-only kinds (`focus`, `type`, `key`) and handoffs are excluded. */
export function isPageAutomatableStep(step: PathStep): boolean {
  switch (step.kind) {
    case "goto":
    case "fill":
    case "waitFor":
      return true;
    case "click":
      return step.locator !== undefined;
    case "read":
      return (
        step.require?.url !== undefined
        || step.require?.locator !== undefined
        || step.require?.text !== undefined
        || step.locator !== undefined
      );
    case "focus":
    case "type":
    case "key":
    case "human":
    case "payment":
    case "submit":
      return false;
    default: {
      const exhaustive: never = step.kind;
      return exhaustive;
    }
  }
}

/**
 * Automated page prefix: the leading run of page-automatable steps. It ends at the
 * first handoff *or* the first step a page cannot run (OS `focus` / `type` / `key`, a
 * locator-less `click`, a bare `read`); nothing past that point is included, so a
 * later page step never runs without the step it depends on.
 */
export function pageStepsUntilHandoff(document: PathDocument): readonly PathStep[] {
  const steps: PathStep[] = [];
  for (const step of document.steps) {
    if (isHandoffStep(step) || !isPageAutomatableStep(step)) break;
    steps.push(step);
  }
  return steps;
}

export function handoffSteps(document: PathDocument): readonly PathStep[] {
  return document.steps.filter(isHandoffStep);
}

export function grantsUsed(document: PathDocument): readonly ("ui.read" | "ui.control")[] {
  const grants = new Set<"ui.read" | "ui.control">(["ui.read"]);
  for (const step of document.steps) {
    if (needsControl(step.kind)) grants.add("ui.control");
    if (step.require?.permission === "ui.control") grants.add("ui.control");
  }
  return [...grants];
}

function needsControl(kind: PathStepKind): boolean {
  switch (kind) {
    case "focus":
    case "click":
    case "type":
    case "key":
    case "goto":
    case "fill":
      return true;
    case "read":
    case "waitFor":
    case "human":
    case "payment":
    case "submit":
      return false;
    default: {
      const exhaustive: never = kind;
      return exhaustive;
    }
  }
}
