import assert from "node:assert/strict";
import { test } from "node:test";
import { loadPath, type PathDocument } from "../../ppomi-path/src/index.ts";
import {
  dryRunKbStarBizWinCertPage,
  dryRunPagePrefix,
  issueUrl,
  kbStarBizWinCertGrants,
  kbStarBizWinCertHandoffs,
  kbStarBizWinCertPagePlaybook,
  loadKbStarBizWinCert,
} from "../example/src/kb-cert-path.ts";
import { pagePlaybookFromPath } from "../src/index.ts";

test("kb-star-biz-win-cert loads: page gotos, human handoffs, ui.read/ui.control, no payment", () => {
  const document = loadKbStarBizWinCert();
  assert.equal(document.id, "kb-star-biz-win-cert");
  assert.equal(document.surface, "os-windows");
  assert.deepEqual(document.allowedOrigins, [
    "https://obank.kbstar.com",
    "https://obiz.kbstar.com",
    "https://obranch.kbstar.com",
  ]);
  const playbook = kbStarBizWinCertPagePlaybook();
  assert.deepEqual(
    playbook.steps.map(step => [step.id, step.kind, step.effect]),
    [
      ["goto-cert-center", "goto", "navigate"],
      ["goto-issue", "goto", "navigate"],
    ],
  );
  assert.equal(playbook.steps[0]?.url, "https://obranch.kbstar.com/quics?page=C100996");
  assert.equal(playbook.steps[1]?.url, "https://obiz.kbstar.com/quics?page=C019623");
  assert.deepEqual(kbStarBizWinCertGrants(), ["ui.read", "ui.control"]);
  assert.equal(document.steps.some(step => step.kind === "payment" || step.kind === "submit"), false);
  assert.equal(kbStarBizWinCertHandoffs().every(step => step.kind === "human"), true);
  const raw = JSON.stringify(document);
  assert.doesNotMatch(raw, /\d{6}-\d{2}-\d{6}|\d{12,14}/);
  assert.doesNotMatch(raw, /approv|deviceApproved|pendingApproval/i);
  assert.equal(document.steps.some(step => step.text !== undefined), false);
});

test("page dry-run completes the two gotos and never reaches a human step", async () => {
  const result = await dryRunKbStarBizWinCertPage();
  assert.equal(result.status, "completed");
  assert.deepEqual(
    result.stepResults.map(row => [row.stepId, row.status, row.driver, row.action]),
    [
      ["goto-cert-center", "ok", "page", "goto"],
      ["goto-issue", "ok", "page", "goto"],
    ],
  );
  assert.equal(result.stepResults.some(row => row.status === "needs_human"), false);
});

test("the live URL is the catalog's goto-issue step and passes the body's navigation gate", () => {
  const document = loadKbStarBizWinCert();
  assert.equal(issueUrl(document), "https://obiz.kbstar.com/quics?page=C019623");

  const undeclaredOrigin: PathDocument = {
    ...document,
    steps: document.steps.map(step =>
      step.id === "goto-issue" ? { ...step, url: "https://example.test/quics?page=C019623" } : step,
    ),
  };
  assert.throws(() => issueUrl(undeclaredOrigin), /goto-issue refused: goto origin https:\/\/example.test is not declared/);
});

test("pagePlaybookFromPath and the dry-run are catalog-agnostic: no goto url → explicit error, kr-cert → empty page prefix", async () => {
  const krCert = loadPath("kr-cert", { version: "0.1.0" });
  const playbook = pagePlaybookFromPath(krCert);
  assert.equal(playbook.id, "kr-cert@0.1.0");
  assert.deepEqual(playbook.steps, []);
  await assert.rejects(() => dryRunPagePrefix(krCert), /kr-cert@0\.1\.0: page dry-run needs a goto step with a url/);
});
