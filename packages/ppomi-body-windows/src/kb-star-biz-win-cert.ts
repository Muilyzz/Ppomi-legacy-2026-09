import {
  DummyPageAdapter,
  FixedPermissionGate,
  PageSurface,
  Runtime,
  publicUrl,
  type PagePlaybook,
  type PagePlaybookStep,
  type PageStepRequirement,
  type RunResult,
} from "../../ppomi-body/src/index.ts";
import {
  grantsUsed,
  handoffSteps,
  isHandoffStep,
  loadPath,
  pageStepsUntilHandoff,
  type PathDocument,
  type PathStep,
  type PathStepRequirement,
} from "../../ppomi-path/src/index.ts";

export const KB_STAR_BIZ_WIN_CERT_ID = "kb-star-biz-win-cert";
export const KB_STAR_BIZ_WIN_CERT_VERSION = "0.1.0";

export function loadKbStarBizWinCert(): PathDocument {
  return loadPath(KB_STAR_BIZ_WIN_CERT_ID, { version: KB_STAR_BIZ_WIN_CERT_VERSION });
}

export function pagePlaybookFromPath(document: PathDocument): PagePlaybook {
  return {
    id: `${document.id}@${document.version}`,
    ...(document.allowedOrigins === undefined ? {} : { allowedOrigins: document.allowedOrigins }),
    steps: pageStepsUntilHandoff(document).map(toPageStep),
  };
}

export function kbStarBizWinCertPagePlaybook(): PagePlaybook {
  return pagePlaybookFromPath(loadKbStarBizWinCert());
}

export function kbStarBizWinCertHandoffs(): readonly PathStep[] {
  return handoffSteps(loadKbStarBizWinCert());
}

export function kbStarBizWinCertGrants(): readonly ("ui.read" | "ui.control")[] {
  return grantsUsed(loadKbStarBizWinCert());
}

/** Fixture: DummyPageAdapter walks the goto prefix and stops before human steps. */
export async function dryRunKbStarBizWinCertPage(): Promise<RunResult> {
  const playbook = kbStarBizWinCertPagePlaybook();
  const first = playbook.steps.find(step => step.kind === "goto" && step.url !== undefined);
  const startUrl = first?.url !== undefined ? originOf(first.url) : "https://obank.kbstar.com/";
  const page = new DummyPageAdapter({
    url: startUrl,
    title: "",
    texts: [],
    locators: [],
  });
  return new Runtime(
    new PageSurface(page, playbook.allowedOrigins),
    new FixedPermissionGate(["ui.read", "ui.control"]),
  ).run(playbook);
}

export function describeKbCertHandoffs(steps: readonly PathStep[]): readonly string[] {
  return steps.filter(isHandoffStep).map(step => `handoff   ${step.id}  ${step.title ?? step.kind}`);
}

export function publicStepUrl(url: string | undefined): string {
  if (url === undefined) return "";
  return publicUrl(url);
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

function originOf(url: string): string {
  try {
    return new URL(url).origin + "/";
  } catch {
    return "https://obank.kbstar.com/";
  }
}
