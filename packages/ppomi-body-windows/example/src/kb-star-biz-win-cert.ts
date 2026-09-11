import { spawn, spawnSync } from "node:child_process";
import { existsSync } from "node:fs";
import { join } from "node:path";
import {
  describeKbCertHandoffs,
  dryRunKbStarBizWinCertPage,
  kbStarBizWinCertGrants,
  kbStarBizWinCertHandoffs,
  kbStarBizWinCertPagePlaybook,
  loadKbStarBizWinCert,
  probeNpki,
  publicStepUrl,
} from "../../src/index.ts";

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

function issueUrl(): string {
  const step = loadKbStarBizWinCert().steps.find(item => item.id === "goto-issue");
  if (step?.url === undefined) throw new Error("kb-star-biz-win-cert goto-issue is missing url");
  return step.url;
}

function writeNpki(): void {
  const probe = probeNpki();
  if (probe.status === "skip") {
    process.stdout.write("  npki     SKIP (not Windows — verify %USERPROFILE%\\AppData\\LocalLow\\NPKI after issue)\n");
    return;
  }
  if (probe.status === "missing") {
    process.stdout.write("  npki     missing — verify AppData\\LocalLow\\NPKI manually after the person finishes\n");
    return;
  }
  const newest = probe.newestMtimeMs === null ? "-" : new Date(probe.newestMtimeMs).toISOString();
  process.stdout.write(`  npki     files=${probe.fileCount} newest=${newest}\n`);
}

async function openIssueInEdge(url: string): Promise<"ok" | "skip"> {
  const edge = edgePath();
  if (edge === undefined) {
    process.stdout.write("  live     SKIP — Edge missing (set PPOMI_EDGE)\n");
    return "skip";
  }
  const child = spawn(edge, ["--no-first-run", "--no-default-browser-check", "--new-window", url], {
    stdio: "ignore",
    detached: true,
  });
  child.unref();
  process.stdout.write(`  live     opened Edge ${publicStepUrl(url)}\n`);
  if (child.pid !== undefined && process.env.PPOMI_KB_CERT_KEEP_EDGE !== "1") {
    await new Promise(done => setTimeout(done, 4_000));
    spawnSync("taskkill", ["/PID", String(child.pid), "/T", "/F"], { stdio: "ignore" });
    process.stdout.write("  live     closed Edge (set PPOMI_KB_CERT_KEEP_EDGE=1 to leave it for the person)\n");
  }
  return "ok";
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
  for (const line of describeKbCertHandoffs(kbStarBizWinCertHandoffs())) {
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

  const opened = await openIssueInEdge(issueUrl());
  if (opened === "ok") {
    process.stdout.write("  live     STOP — remaining steps are human (OTP, passwords, UAC, final confirm)\n");
  }
  writeNpki();
}

main().catch(error => {
  const message = error instanceof Error ? error.message : String(error);
  process.stderr.write(`kb-star-biz-win-cert: FAIL\n  ${message}\n`);
  process.exitCode = 1;
});
