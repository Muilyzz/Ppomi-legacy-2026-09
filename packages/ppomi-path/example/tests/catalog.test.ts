import assert from "node:assert/strict";
import { mkdtemp, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";
import { test } from "node:test";
import { fileURLToPath } from "node:url";
import { CatalogError, loadPathCatalogFile, validatePathCatalog } from "../src/catalog.ts";

const fixture = path.join(path.dirname(fileURLToPath(import.meta.url)), "..", "fixtures", "catalog.json");

test("bundled fixture catalog loads and validates", async () => {
  const catalog = await loadPathCatalogFile(fixture);
  assert.equal(catalog.catalogId, "ppomi-path-sample");
  assert.equal(catalog.paths.length, 2);
  assert.equal(catalog.paths[0]?.id, "sample-browse");
  assert.equal(catalog.paths[1]?.financialSubmit, "human");
});

test("rejects a catalog with a duplicate path id", () => {
  assert.throws(() => validatePathCatalog({
    schemaVersion: 1,
    catalogId: "dup",
    version: "1.0.0",
    paths: [
      {
        id: "one",
        title: "A",
        bodyKind: "macos",
        grant: "ui.read",
        financialSubmit: false,
        steps: [{ id: "open", kind: "open", title: "Open" }],
      },
      {
        id: "one",
        title: "B",
        bodyKind: "windows",
        grant: "ui.read",
        financialSubmit: false,
        steps: [{ id: "open", kind: "open", title: "Open" }],
      },
    ],
  }), CatalogError);
});

test("payment steps require a target", async () => {
  const dir = await mkdtemp(path.join(tmpdir(), "ppomi-path-"));
  const file = path.join(dir, "bad.json");
  await writeFile(file, JSON.stringify({
    schemaVersion: 1,
    catalogId: "bad",
    version: "1.0.0",
    paths: [{
      id: "pay",
      title: "Pay",
      bodyKind: "windows",
      grant: "ui.control",
      financialSubmit: "human",
      steps: [{ id: "pay", kind: "payment", title: "Pay" }],
    }],
  }));
  await assert.rejects(() => loadPathCatalogFile(file), /needs target/);
});
