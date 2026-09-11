import {
  DummyPageAdapter,
  FixedPermissionGate,
  PageSurface,
  Runtime,
  navigationRefusal,
  type PagePlaybook,
  type RunResult,
} from "../../../ppomi-body/src/index.ts";
import {
  grantsUsed,
  handoffSteps,
  isHandoffStep,
  loadPath,
  type PathDocument,
  type PathStep,
} from "../../../ppomi-path/src/index.ts";
import { pagePlaybookFromPath } from "../../src/index.ts";

/**
 * Example glue for one catalog entry. The body package stays bank-agnostic: every
 * URL below comes from `catalogs/paths/kb-star-biz-win-cert/<version>.json`.
 */
export const KB_STAR_BIZ_WIN_CERT_ID = "kb-star-biz-win-cert";
export const KB_STAR_BIZ_WIN_CERT_VERSION = "0.1.0";
export const KB_STAR_BIZ_WIN_CERT_ISSUE_STEP = "goto-issue";

export function loadKbStarBizWinCert(): PathDocument {
  return loadPath(KB_STAR_BIZ_WIN_CERT_ID, { version: KB_STAR_BIZ_WIN_CERT_VERSION });
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

/**
 * Fixture: `DummyPageAdapter` starts on the first `goto`'s origin and walks the page
 * prefix through `Runtime` + `PageSurface`. The prefix never contains a human step.
 */
export async function dryRunPagePrefix(document: PathDocument): Promise<RunResult> {
  const playbook = pagePlaybookFromPath(document);
  const first = playbook.steps.find(step => step.kind === "goto" && step.url !== undefined);
  if (first?.url === undefined) {
    throw new Error(`${playbook.id}: page dry-run needs a goto step with a url`);
  }
  const page = new DummyPageAdapter({
    url: `${new URL(first.url).origin}/`,
    title: "",
    texts: [],
    locators: [],
  });
  return new Runtime(
    new PageSurface(page, playbook.allowedOrigins),
    new FixedPermissionGate(["ui.read", "ui.control"]),
  ).run(playbook);
}

export function dryRunKbStarBizWinCertPage(): Promise<RunResult> {
  return dryRunPagePrefix(loadKbStarBizWinCert());
}

export function describeHandoffs(steps: readonly PathStep[]): readonly string[] {
  return steps.filter(isHandoffStep).map(step => `handoff   ${step.id}  ${step.title ?? step.kind}`);
}

/**
 * The one URL the live example opens. Same gate as `PageSurface.goto`: absolute,
 * credential-free http(s), on a declared origin — a catalog edit cannot widen it.
 */
export function issueUrl(document: PathDocument): string {
  const step = document.steps.find(item => item.id === KB_STAR_BIZ_WIN_CERT_ISSUE_STEP);
  if (step?.kind !== "goto" || step.url === undefined) {
    throw new Error(`${document.id}: ${KB_STAR_BIZ_WIN_CERT_ISSUE_STEP} is not a goto with a url`);
  }
  const refusal = navigationRefusal(step.url, document.allowedOrigins);
  if (refusal !== null) throw new Error(`${document.id}: ${KB_STAR_BIZ_WIN_CERT_ISSUE_STEP} refused: ${refusal}`);
  return step.url;
}
