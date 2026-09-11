import { InMemoryLog, MockAccount, MockBody, MockPath } from "./mocks.ts";
import { orchestrate } from "./orchestrate.ts";
import type { BodyKind, Grant } from "./ports.ts";
import { parseBodyKind, RealBodyBridge } from "./real-body.ts";

interface CliOptions {
  readonly intent: string;
  readonly body: BodyKind;
  readonly grants: readonly Grant[];
}

function parseArgs(argv: readonly string[]): CliOptions {
  let intent = "browse";
  let body = parseBodyKind(process.env.PPOMI_BODY);
  const grants: Grant[] = ["ui.read", "ui.control"];
  for (let i = 0; i < argv.length; i += 1) {
    const arg = argv[i];
    if (arg === "--intent") {
      const value = argv[i + 1];
      if (value === undefined) throw new Error("--intent needs text");
      intent = value;
      i += 1;
      continue;
    }
    if (arg === "--body") {
      const value = argv[i + 1];
      body = parseBodyKind(value);
      i += 1;
      continue;
    }
    if (arg === "--deny-control") {
      grants.splice(0, grants.length, "ui.read");
      continue;
    }
    if (arg === "--help" || arg === "-h") {
      printHelp();
      process.exit(0);
    }
    if (!arg.startsWith("-")) {
      intent = arg;
      continue;
    }
    throw new Error(`unknown argument: ${arg}`);
  }
  return { intent, body, grants };
}

function printHelp(): void {
  process.stdout.write(`ppomi-brain example — orchestrate against mocks

Usage:
  node --experimental-strip-types src/main.ts [intent] [--body mock|macos|windows] [--deny-control]

Default intent: browse (sample-browse).
Default body: mock. PPOMI_BODY=macos|windows runs the matching ppomi-body-* example.

No Clerk keys. Financial submit stays human (blocked on the mock body).
`);
}

async function main(): Promise<void> {
  const options = parseArgs(process.argv.slice(2));
  const memory = new InMemoryLog();
  const body = options.body === "mock" ? new MockBody() : new RealBodyBridge(options.body);
  const result = await orchestrate({
    intent: options.intent,
    path: new MockPath(),
    account: new MockAccount(options.grants),
    body,
    memory,
  });

  const ok = result.status === "completed";
  process.stdout.write(`ppomi-brain example: ${ok ? "PASS" : result.status === "stopped" || result.status === "grant_denied" || result.status === "path_not_found" ? result.status.toUpperCase() : "FAIL"}\n`);
  process.stdout.write(`  intent  ${options.intent}\n`);
  process.stdout.write(`  path    ${result.pathId ?? "(none)"}\n`);
  process.stdout.write(`  body    ${result.body}\n`);
  process.stdout.write(`  status  ${result.status}  ${result.note}\n`);
  for (const step of result.steps) {
    process.stdout.write(`    - ${step.stepId}  ${step.outcome}  ${step.note}\n`);
  }
  for (const record of memory.list()) {
    process.stdout.write(`  memory  ${record.pathId} via ${record.body} → ${record.status}\n`);
  }

  if (result.status === "path_not_found" || result.status === "grant_denied") {
    process.exitCode = 1;
  }
}

main().catch(error => {
  const message = error instanceof Error ? error.message : String(error);
  process.stderr.write(`ppomi-brain example: FAIL\n  ${message}\n`);
  process.exitCode = 1;
});
