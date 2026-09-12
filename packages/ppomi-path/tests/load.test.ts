import assert from "node:assert/strict";
import { mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { test } from "node:test";
import {
  PathError,
  defaultCatalogRoot,
  loadPath,
  loadPathCatalog,
  validatePathDocument,
} from "../src/index.ts";

test("loads the sample kr-cert path from the versioned JSON catalog", () => {
  const catalog = loadPathCatalog();
  assert.equal(catalog.schemaVersion, 1);
  assert.deepEqual(catalog.paths, [
    { id: "kr-cert", version: "0.1.0", href: "kr-cert/0.1.0.json" },
    { id: "kb-star-biz-iphone", version: "0.1.0", href: "kb-star-biz-iphone/0.1.0.json" },
    { id: "kb-star-biz-win-cert", version: "0.1.0", href: "kb-star-biz-win-cert/0.1.0.json" },
  ]);

  const document = loadPath("kr-cert");
  assert.equal(document.id, "kr-cert");
  assert.equal(document.version, "0.1.0");
  assert.equal(document.surface, "os-windows");
  assert.equal(document.legacyPackage, "playbook-kr-cert");
  assert.deepEqual(
    document.steps.map(step => step.kind),
    ["focus", "read", "click", "type", "read", "human", "payment", "submit"],
  );
  assert.equal(document.steps.some(step => step.target === "결제하기"), true);
  assert.equal(document.steps.some(step => step.target === "제출"), true);
  assert.equal(document.steps.find(step => step.id === "open-next")?.effect, "navigate");
  assert.equal(document.steps.find(step => step.id === "fill-business-kind")?.effect, "input");
  assert.equal(document.steps.find(step => step.id === "pay-certificate")?.effect, "commit");
  assert.equal(document.steps.find(step => step.id === "submit-application")?.effect, "commit");
  const raw = JSON.stringify(document);
  assert.doesNotMatch(raw, /approv|deviceApproved|pendingApproval/i);
  assert.doesNotMatch(raw, /주민등록|인증서 비밀번호|deviceApproved/i);
  assert.ok(defaultCatalogRoot().endsWith(`${path.sep}catalogs${path.sep}paths`));
});

test("loads kb-star-biz-iphone: human login, no payment, no account digits", () => {
  const document = loadPath("kb-star-biz-iphone");
  assert.equal(document.surface, "iphone-mirroring");
  assert.deepEqual(
    document.steps.map(step => step.kind),
    ["key", "focus", "human", "click", "human", "read"],
  );
  const goHome = document.steps.find(step => step.id === "go-home");
  assert.equal(goHome?.target, "home");
  assert.equal(goHome?.effect, "navigate");
  assert.match(goHome?.title ?? "", /cold start|fromStep|pause\/resume/i);
  assert.equal(document.steps.find(step => step.id === "open-kb")?.target, "KB스타기업뱅킹");
  assert.equal(document.steps.find(step => step.id === "open-accounts")?.effect, "navigate");
  assert.equal(document.steps.find(step => step.id === "read-account")?.require?.permission, "ui.read");
  assert.equal(document.steps.some(step => step.kind === "payment" || step.kind === "submit"), false);
  const raw = JSON.stringify(document);
  assert.doesNotMatch(raw, /\d{6}-\d{2}-\d{6}|\d{12,14}/);
  assert.doesNotMatch(raw, /approv|deviceApproved|주민등록/i);
});

test("loads kb-star-biz-win-cert: page gotos, human handoffs, no payment, no secrets", () => {
  const document = loadPath("kb-star-biz-win-cert");
  assert.equal(document.surface, "os-windows");
  assert.deepEqual(
    document.steps.map(step => step.kind),
    ["goto", "goto", "human", "human", "human", "human", "human", "human", "human", "human", "human"],
  );
  assert.equal(document.steps.find(step => step.id === "goto-issue")?.effect, "navigate");
  assert.equal(document.steps.find(step => step.id === "goto-issue")?.require?.permission, "ui.control");
  assert.equal(document.steps.some(step => step.kind === "payment" || step.kind === "submit"), false);
  const raw = JSON.stringify(document);
  assert.doesNotMatch(raw, /\d{6}-\d{2}-\d{6}|\d{12,14}/);
  assert.doesNotMatch(raw, /approv|deviceApproved|pendingApproval/i);
  assert.equal(document.steps.some(step => step.text !== undefined), false);
});

test("loadPath selects an explicit version and rejects unknown ids", () => {
  assert.equal(loadPath("kr-cert", { version: "0.1.0" }).version, "0.1.0");
  assert.throws(
    () => loadPath("missing-path"),
    error => error instanceof PathError && error.code === "path_not_found",
  );
  assert.throws(
    () => loadPath("kr-cert", { version: "9.9.9" }),
    error => error instanceof PathError && error.code === "path_version",
  );
});

test("validatePathDocument rejects bad schema, kinds, and payment without a target", () => {
  const valid = loadPath("kr-cert");
  assert.throws(
    () => validatePathDocument({ ...valid, schemaVersion: 2 }),
    error => error instanceof PathError && error.code === "schema_version",
  );
  assert.throws(
    () => validatePathDocument({ ...valid, steps: [{ id: "x", kind: "adapter" }] }),
    error => error instanceof PathError && error.code === "step_kind",
  );
  assert.throws(
    () => validatePathDocument({
      ...valid,
      steps: [{ id: "pay", kind: "payment" }],
    }),
    error => error instanceof PathError && error.code === "step_target",
  );
  assert.throws(
    () => validatePathDocument({
      ...valid,
      steps: [{ id: "go-home", kind: "key" }],
    }),
    error => error instanceof PathError && error.code === "step_target",
  );
});

test("accepts core effect, allowedOrigins, and require.wait", () => {
  const document = validatePathDocument({
    schemaVersion: 1,
    id: "demo-page",
    version: "0.1.0",
    title: "Demo page",
    surface: "page",
    allowedOrigins: ["https://example.test"],
    steps: [
      {
        id: "open-form",
        kind: "goto",
        url: "https://example.test/form",
        effect: "navigate",
        require: { wait: 250 },
      },
      { id: "fill-name", kind: "fill", locator: "#name", text: "fixture", effect: "input" },
    ],
  });
  assert.deepEqual(document.allowedOrigins, ["https://example.test"]);
  assert.equal(document.steps[0]?.effect, "navigate");
  assert.equal(document.steps[0]?.require?.wait, 250);
  assert.equal(document.steps[1]?.effect, "input");
});

test("rejects unknown effect, non-origin allowedOrigins, and non-positive wait", () => {
  const valid = loadPath("kr-cert");
  assert.throws(
    () => validatePathDocument({
      ...valid,
      steps: [{ id: "go", kind: "click", target: "Next", effect: "adapter" }],
    }),
    error => error instanceof PathError && error.code === "effect",
  );
  assert.throws(
    () => validatePathDocument({ ...valid, allowedOrigins: ["javascript:alert(1)"] }),
    error => error instanceof PathError && error.code === "origin",
  );
  assert.throws(
    () => validatePathDocument({
      ...valid,
      steps: [{ id: "go", kind: "read", require: { wait: 0 } }],
    }),
    error => error instanceof PathError && error.code === "wait",
  );
});

test("catalog href cannot escape the catalog root", () => {
  const root = mkdtempSync(path.join(tmpdir(), "ppomi-path-"));
  writeFileSync(
    path.join(root, "index.json"),
    JSON.stringify({
      schemaVersion: 1,
      paths: [{ id: "escape", version: "0.1.0", href: "../secret.json" }],
    }),
  );
  assert.throws(
    () => loadPathCatalog(root),
    error => error instanceof PathError && error.code === "href",
  );
});
