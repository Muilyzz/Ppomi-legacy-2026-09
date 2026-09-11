import { existsSync } from "node:fs";
import { join } from "node:path";
import { probeNpki, type NpkiProbe } from "../../src/index.ts";
import { CLOSE_EDGE_ENV, openInEdge } from "./kb-cert-edge.ts";
import {
  describeHandoffs,
  dryRunKbStarBizWinCertPage,
  issueUrl,
  kbStarBizWinCertGrants,
  kbStarBizWinCertHandoffs,
  kbStarBizWinCertPagePlaybook,
  loadKbStarBizWinCert,
} from "./kb-cert-path.ts";

const LIVE_COMMAND =
  "PPOMI_BODY_LIVE=1 node --experimental-strip-types packages/ppomi-body-windows/example/src/kb-star-biz-win-cert.ts";

function parseArgs(argv: readonly string[]): { readonly probeOnly: boolean } {
  return { probeOnly: argv.includes("--probe-npki") };
}

function edgePath(): string | undefined {
  const candidates = [
    process.env.PPOMI_EDGE,
    process.env["ProgramFiles(x86)"] && join(process.env["ProgramFiles(x86)"], "Microsoft", "Edge", "Application", "msedge.exe"),
    process.env.ProgramFiles && join(process.env.ProgramFiles, "Microsoft", "Edge", "Application", "msedge.exe"),
  ].filter((candidate): candidate is string => typeof candidate === "string");
  return candidates.find(candidate => existsSync(candidate));
}

/** Count + newest mtime only. Never a path, a filename, or a DN. */
function describeNpki(probe: NpkiProbe): string {
  switch (probe.status) {
    case "skip":
      return "SKIP (not Windows — verify %USERPROFILE%\\AppData\\LocalLow\\NPKI after issue)";
    case "missing":
      return "missing — verify AppData\\LocalLow\\NPKI manually after the person finishes";
    case "refused":
      return "refused — PPOMI_NPKI_ROOT must be an absolute directory under %USERPROFILE% (not the profile itself, not a link)";
    case "ok": {
      const newest = probe.newestMtimeMs === null ? "-" : new Date(probe.newestMtimeMs).toISOString();
      return `files=${probe.fileCount} newest=${newest} root=${probe.root}${probe.truncated ? " (truncated)" : ""}`;
    }
    default: {
      const exhaustive: never = probe.status;
      return String(exhaustive);
    }
  }
}

function writeNpki(): void {
  process.stdout.write(`  npki     ${describeNpki(probeNpki())}\n`);
}

async function main(): Promise<void> {
  const options = parseArgs(process.argv.slice(2));
  const document = loadKbStarBizWinCert();
  const playbook = kbStarBizWinCertPagePlaybook();
  const grants = kbStarBizWinCertGrants().join("+");

  process.stdout.write(`kb-star-biz-win-cert@${document.version}\n`);
  process.stdout.write(`  grants   ${grants}  (no payment/submit auto)\n`);
  process.stdout.write(`  page     ${playbook.steps.map(step => step.id).join(" → ")}\n`);

  if (options.probeOnly) {
    writeNpki();
    return;
  }

  const dry = await dryRunKbStarBizWinCertPage();
  if (dry.status !== "completed") {
    throw new Error(`page dry-run ${dry.status} ${dry.stopReason ?? dry.invalid?.code ?? ""}`);
  }
  process.stdout.write("  page     dry-run PASS (DummyPageAdapter)\n");
  for (const line of describeHandoffs(kbStarBizWinCertHandoffs())) {
    process.stdout.write(`  ${line}\n`);
  }

  const live = process.env.PPOMI_BODY_LIVE === "1";
  if (!live) {
    process.stdout.write(`  live     dry-run — ${LIVE_COMMAND}\n`);
    writeNpki();
    return;
  }
  if (process.platform !== "win32") {
    process.stdout.write("  live     SKIP (not Windows)\n");
    writeNpki();
    return;
  }
  const edge = edgePath();
  if (edge === undefined) {
    process.stdout.write("  live     SKIP — Edge missing (set PPOMI_EDGE)\n");
    writeNpki();
    return;
  }

  const opened = await openInEdge({
    edge,
    url: issueUrl(document),
    closeEdge: process.env[CLOSE_EDGE_ENV] === "1",
  });
  for (const line of opened.lines) {
    process.stdout.write(`  live     ${line}\n`);
  }
  process.stdout.write("  live     STOP — remaining steps are human (OTP, passwords, UAC, final confirm)\n");
  writeNpki();
}

main().catch(error => {
  const message = error instanceof Error ? error.message : String(error);
  process.stderr.write(`kb-star-biz-win-cert: FAIL\n  ${message}\n`);
  process.exitCode = 1;
});
