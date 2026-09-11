import path from "node:path";
import { fileURLToPath } from "node:url";
import {
  CatalogError,
  findRepoCatalogRoot,
  loadLegacyCatalog,
  loadPathCatalogFile,
  type LegacyCatalogSummary,
  type PathCatalog,
} from "./catalog.ts";

const here = path.dirname(fileURLToPath(import.meta.url));
const exampleRoot = path.resolve(here, "..");
const defaultFixture = path.join(exampleRoot, "fixtures", "catalog.json");

interface CliOptions {
  readonly fixture: string;
  readonly legacy: boolean;
  readonly catalogRoot: string | null;
}

function parseArgs(argv: readonly string[]): CliOptions {
  let fixture = defaultFixture;
  let legacy = false;
  let catalogRoot: string | null = null;
  for (let i = 0; i < argv.length; i += 1) {
    const arg = argv[i];
    if (arg === "--legacy") {
      legacy = true;
      continue;
    }
    if (arg === "--fixture") {
      const value = argv[i + 1];
      if (value === undefined) throw new CatalogError("--fixture needs a path");
      fixture = path.resolve(value);
      i += 1;
      continue;
    }
    if (arg === "--catalog") {
      const value = argv[i + 1];
      if (value === undefined) throw new CatalogError("--catalog needs a directory");
      catalogRoot = path.resolve(value);
      legacy = true;
      i += 1;
      continue;
    }
    if (arg === "--help" || arg === "-h") {
      printHelp();
      process.exit(0);
    }
    throw new CatalogError(`unknown argument: ${arg}`);
  }
  return { fixture, legacy, catalogRoot };
}

function printHelp(): void {
  process.stdout.write(`ppomi-path example — catalog load / validate

Usage:
  node --experimental-strip-types src/main.ts [--fixture <json>] [--legacy] [--catalog <dir>]

  --fixture   Versioned path catalog JSON (default: fixtures/catalog.json)
  --legacy    Also load this repo's Ppomi/Sources/Ppomi/Catalog via hub/lib/catalog.js
  --catalog   Legacy Catalog directory (implies --legacy)

Any machine. No Clerk keys. No device.
`);
}

function printPathCatalog(catalog: PathCatalog, source: string): void {
  process.stdout.write(`ppomi-path example: PASS\n`);
  process.stdout.write(`  source     ${source}\n`);
  process.stdout.write(`  catalogId  ${catalog.catalogId}  v${catalog.version}  schema ${catalog.schemaVersion}\n`);
  process.stdout.write(`  paths      ${catalog.paths.length}\n`);
  for (const entry of catalog.paths) {
    const submit = entry.financialSubmit === false ? "no-submit" : "financialSubmit=human";
    process.stdout.write(`    - ${entry.id}  body=${entry.bodyKind}  grant=${entry.grant}  ${submit}  steps=${entry.steps.length}\n`);
  }
}

function printLegacy(summary: LegacyCatalogSummary): void {
  process.stdout.write(`  legacy     ${summary.root}\n`);
  process.stdout.write(`  playbooks  ${summary.playbooks.length}\n`);
  for (const playbook of summary.playbooks) {
    process.stdout.write(`    - ${playbook.id}  ${playbook.name}  v${playbook.version}  caps=${playbook.capabilities}\n`);
  }
}

async function main(): Promise<void> {
  const options = parseArgs(process.argv.slice(2));
  const catalog = await loadPathCatalogFile(options.fixture);
  printPathCatalog(catalog, options.fixture);

  if (!options.legacy) return;

  const root = options.catalogRoot ?? await findRepoCatalogRoot(exampleRoot);
  if (root === null) {
    process.stdout.write("  legacy     SKIP (Ppomi/Sources/Ppomi/Catalog not found)\n");
    return;
  }
  printLegacy(await loadLegacyCatalog(root));
}

main().catch(error => {
  const message = error instanceof Error ? error.message : String(error);
  process.stderr.write(`ppomi-path example: FAIL\n  ${message}\n`);
  process.exitCode = 1;
});
