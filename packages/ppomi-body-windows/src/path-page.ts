import type { PagePlaybook, PagePlaybookStep, PageStepRequirement } from "../../ppomi-body/src/index.ts";
import {
  pageStepsUntilHandoff,
  type PathDocument,
  type PathStep,
  type PathStepRequirement,
} from "../../ppomi-path/src/index.ts";

/**
 * The page-automatable prefix of a path as a `PagePlaybook` for `PageSurface`.
 * Generic over any catalog document; nothing here knows a bank or a URL.
 * Follow-up: this mapper belongs in `ppomi-body` (owner of `PagePlaybook`), not an OS body.
 */
export function pagePlaybookFromPath(document: PathDocument): PagePlaybook {
  return {
    id: `${document.id}@${document.version}`,
    ...(document.allowedOrigins === undefined ? {} : { allowedOrigins: document.allowedOrigins }),
    steps: pageStepsUntilHandoff(document).map(toPageStep),
  };
}

function toPageStep(step: PathStep): PagePlaybookStep {
  const require = toPageRequire(step.require);
  switch (step.kind) {
    case "goto":
      return {
        id: step.id,
        kind: "goto",
        ...(step.url === undefined ? {} : { url: step.url }),
        ...(step.effect === undefined ? {} : { effect: step.effect }),
        ...(require === undefined ? {} : { require }),
      };
    case "fill":
      return {
        id: step.id,
        kind: "fill",
        ...(step.locator === undefined ? {} : { locator: step.locator }),
        ...(step.text === undefined ? {} : { text: step.text }),
        ...(step.effect === undefined ? {} : { effect: step.effect }),
        ...(require === undefined ? {} : { require }),
      };
    case "waitFor":
      return {
        id: step.id,
        kind: "waitFor",
        ...(step.locator === undefined ? {} : { locator: step.locator }),
        ...(require === undefined ? {} : { require }),
      };
    case "click":
      return {
        id: step.id,
        kind: "click",
        ...(step.locator === undefined ? {} : { locator: step.locator }),
        ...(step.effect === undefined ? {} : { effect: step.effect }),
        ...(require === undefined ? {} : { require }),
      };
    case "read":
      return { id: step.id, kind: "read", ...(require === undefined ? {} : { require }) };
    case "focus":
    case "type":
    case "key":
    case "human":
    case "payment":
    case "submit":
      throw new Error(`page playbook cannot include ${step.kind}`);
    default: {
      const exhaustive: never = step.kind;
      throw new Error(`unhandled path step kind: ${String(exhaustive)}`);
    }
  }
}

function toPageRequire(require: PathStepRequirement | undefined): PageStepRequirement | undefined {
  if (require === undefined) return undefined;
  return {
    ...(require.permission !== undefined ? { permission: require.permission } : {}),
    ...(require.url !== undefined ? { url: require.url } : {}),
    ...(require.wait !== undefined ? { wait: require.wait } : {}),
    ...(require.text !== undefined ? { texts: require.text } : {}),
    ...(require.locator !== undefined ? { locators: [require.locator] } : {}),
  };
}
