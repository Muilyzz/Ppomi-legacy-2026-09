// Selection and verification rules for `build-windows-executor.mjs --download`.
// `gh` is a stub; nothing here touches the network or a real artifact.
//   node --test scripts/tests/executor-artifact.test.mjs
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { createHash } from "node:crypto";
import { chmodSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { delimiter, dirname, join, resolve } from "node:path";
import { test } from "node:test";
import { fileURLToPath } from "node:url";
import {
  ArtifactError,
  EXE,
  SUMS,
  parseSha256Sums,
  selectRun,
  verifyArtifactDir,
} from "../lib/executor-artifact.mjs";

const here = dirname(fileURLToPath(import.meta.url));
const cli = resolve(here, "..", "build-windows-executor.mjs");
const SHA = "0123456789abcdef0123456789abcdef01234567";

const pushRun = { databaseId: 101, headSha: SHA, headBranch: "main", event: "push" };
const completed = { status: "completed", conclusion: "success", workflowName: "windows-executor" };

/** A `gh` stub that records every argv and answers from `replies` in order. */
function stubGh(...replies) {
  const calls = [];
  const gh = (argv) => {
    calls.push(argv);
    const reply = replies.shift() ?? { status: 1, stdout: "", stderr: "unexpected gh call" };
    return { status: 0, stdout: "", stderr: "", ...reply };
  };
  gh.calls = calls;
  return gh;
}

const json = (value) => ({ stdout: JSON.stringify(value) });

test("default search asks only for successful push runs of the workflow on main", () => {
  const gh = stubGh(json([pushRun]));
  const selected = selectRun(gh);
  assert.deepEqual(selected, { id: 101, headSha: SHA, headBranch: "main", event: "push" });
  assert.equal(gh.calls.length, 1);
  const argv = gh.calls[0];
  assert.deepEqual(argv.slice(0, 2), ["run", "list"]);
  for (const pair of [["--repo", "Muilyzz/Ppomi"], ["--workflow", "windows-executor.yml"], ["--branch", "main"], ["--event", "push"], ["--status", "success"], ["--limit", "1"]]) {
    const at = argv.indexOf(pair[0]);
    assert.ok(at >= 0, `${pair[0]} missing from ${argv.join(" ")}`);
    assert.equal(argv[at + 1], pair[1]);
  }
  assert.ok(!argv.includes("pull_request"));
});

test("--branch narrows the search but the event stays push", () => {
  const gh = stubGh(json([{ ...pushRun, headBranch: "release/1.0" }]));
  const selected = selectRun(gh, { branch: "release/1.0" });
  assert.equal(selected.headBranch, "release/1.0");
  const argv = gh.calls[0];
  assert.equal(argv[argv.indexOf("--branch") + 1], "release/1.0");
  assert.equal(argv[argv.indexOf("--event") + 1], "push");
});

test("no eligible run fails closed with a hint", () => {
  assert.throws(() => selectRun(stubGh(json([]))), (error) => error instanceof ArtifactError && /no successful push run/.test(error.message) && /--run <id>/.test(error.message));
});

test("a listed run that is somehow a pull_request is still refused", () => {
  const gh = stubGh(json([{ ...pushRun, event: "pull_request" }]));
  assert.throws(() => selectRun(gh), (error) => error instanceof ArtifactError && /pull_request/.test(error.message));
});

test("a listed run without a full commit SHA is refused", () => {
  const gh = stubGh(json([{ ...pushRun, headSha: "abc" }]));
  assert.throws(() => selectRun(gh), (error) => error instanceof ArtifactError && /commit SHA/.test(error.message));
});

test("--run <id> views that run only and accepts a completed successful push", () => {
  const gh = stubGh(json({ ...pushRun, ...completed }));
  const selected = selectRun(gh, { runId: "101" });
  assert.equal(selected.id, 101);
  assert.equal(selected.headSha, SHA);
  assert.equal(gh.calls.length, 1);
  assert.deepEqual(gh.calls[0].slice(0, 3), ["run", "view", "101"]);
  assert.ok(gh.calls[0].includes("--repo"));
});

test("--run <id> accepts a workflow_dispatch run and reports its branch", () => {
  const gh = stubGh(json({ ...pushRun, ...completed, databaseId: 202, headBranch: "feat/x", event: "workflow_dispatch" }));
  const selected = selectRun(gh, { runId: "202" });
  assert.equal(selected.event, "workflow_dispatch");
  assert.equal(selected.headBranch, "feat/x");
});

test("--run <id> refuses a pull_request run even when it succeeded", () => {
  const gh = stubGh(json({ ...pushRun, ...completed, event: "pull_request" }));
  assert.throws(() => selectRun(gh, { runId: "101" }), (error) => error instanceof ArtifactError && /pull_request/.test(error.message));
});

test("--run <id> refuses runs that are not completed/success", () => {
  for (const state of [{ status: "in_progress", conclusion: null }, { status: "completed", conclusion: "failure" }, { status: "completed", conclusion: "cancelled" }]) {
    const gh = stubGh(json({ ...pushRun, ...completed, ...state }));
    assert.throws(() => selectRun(gh, { runId: "101" }), (error) => error instanceof ArtifactError && /not a successful run/.test(error.message), JSON.stringify(state));
  }
});

test("--run <id> refuses a run from another workflow", () => {
  const gh = stubGh(json({ ...pushRun, ...completed, workflowName: "release" }));
  assert.throws(() => selectRun(gh, { runId: "101" }), (error) => error instanceof ArtifactError && /workflow release/.test(error.message));
});

test("--run must be numeric and gh is never called otherwise", () => {
  const gh = stubGh();
  assert.throws(() => selectRun(gh, { runId: "latest" }), (error) => error instanceof ArtifactError && /numeric run id/.test(error.message));
  assert.throws(() => selectRun(gh, { runId: "101; rm -rf" }), ArtifactError);
  assert.equal(gh.calls.length, 0);
});

test("gh failures and invalid JSON surface as ArtifactError", () => {
  assert.throws(() => selectRun(stubGh({ status: 1, stderr: "gh: not logged in\n" })), (error) => error instanceof ArtifactError && error.message === "gh: not logged in");
  assert.throws(() => selectRun(stubGh({ status: 0, stdout: "<html>" })), (error) => error instanceof ArtifactError && /invalid JSON/.test(error.message));
});

test("SHA256SUMS parsing: sha256sum format, binary marker, CRLF, comments, other files", () => {
  const hex = "a".repeat(64);
  assert.equal(parseSha256Sums(`${hex}  ${EXE}\n`, EXE), hex);
  assert.equal(parseSha256Sums(`${hex.toUpperCase()} *${EXE}\r\n`, EXE), hex);
  assert.equal(parseSha256Sums(`# built by CI\r\n${"b".repeat(64)}  other.exe\r\n${hex}  ${EXE}\r\n`, EXE), hex);
  assert.equal(parseSha256Sums(`${hex}  other.exe\n`, EXE), null);
  assert.equal(parseSha256Sums(`${"a".repeat(63)}  ${EXE}\n`, EXE), null);
  assert.equal(parseSha256Sums("", EXE), null);
});

function artifactDir(files) {
  const dir = mkdtempSync(join(tmpdir(), "ppomi-artifact-test-"));
  for (const [name, content] of Object.entries(files)) writeFileSync(join(dir, name), content);
  return dir;
}

const bytes = Buffer.from("MZ not really an exe");
const bytesHash = createHash("sha256").update(bytes).digest("hex");

test("verifyArtifactDir accepts a matching exe and returns its hash", () => {
  const dir = artifactDir({ [EXE]: bytes, [SUMS]: `${bytesHash}  ${EXE}\n` });
  try {
    assert.equal(verifyArtifactDir(dir), bytesHash);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test("verifyArtifactDir fails closed on missing exe, missing SUMS, unlisted exe, or mismatch", () => {
  const cases = [
    [{ [SUMS]: `${bytesHash}  ${EXE}\n` }, new RegExp(`has no ${EXE}`)],
    [{ [EXE]: bytes }, /has no SHA256SUMS; refusing/],
    [{ [EXE]: bytes, [SUMS]: `${bytesHash}  something-else.exe\n` }, /does not list/],
    [{ [EXE]: bytes, [SUMS]: `${"0".repeat(64)}  ${EXE}\n` }, /does not match/],
    [{ [EXE]: bytes, [SUMS]: "" }, /does not list/],
  ];
  for (const [files, expected] of cases) {
    const dir = artifactDir(files);
    try {
      assert.throws(() => verifyArtifactDir(dir), (error) => error instanceof ArtifactError && expected.test(error.message), Object.keys(files).join(","));
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  }
});

// CLI wiring: a fake `gh` on PATH drives `--download` through the real script.
// Only refusal paths run here so nothing is ever staged into the working tree.
function fakeGhDir(script) {
  const dir = mkdtempSync(join(tmpdir(), "ppomi-fake-gh-"));
  const impl = join(dir, "fake-gh.mjs");
  writeFileSync(impl, script);
  writeFileSync(join(dir, "gh"), `#!/bin/sh\nexec node "${impl}" "$@"\n`);
  chmodSync(join(dir, "gh"), 0o755);
  writeFileSync(join(dir, "gh.cmd"), `@echo off\r\nnode "${impl}" %*\r\n`);
  return dir;
}

function runCli(ghDir, argv) {
  return spawnSync(process.execPath, [cli, ...argv], {
    encoding: "utf8",
    env: { ...process.env, PATH: `${ghDir}${delimiter}${process.env.PATH ?? ""}` },
  });
}

test("CLI: --download --run refuses a pull_request run before downloading anything", () => {
  const ghDir = fakeGhDir(`
    const argv = process.argv.slice(2);
    if (argv[0] === "run" && argv[1] === "view") {
      process.stdout.write(JSON.stringify({ databaseId: 7, headSha: "${SHA}", headBranch: "feat/fork", event: "pull_request", status: "completed", conclusion: "success", workflowName: "windows-executor" }));
      process.exit(0);
    }
    process.stderr.write("fake gh: unexpected " + argv.join(" ") + "\\n");
    process.exit(9);
  `);
  try {
    const result = runCli(ghDir, ["--download", "--rid", "win-x64", "--run", "7"]);
    assert.equal(result.status, 1, result.stderr);
    assert.match(result.stderr, /run 7 was triggered by pull_request/);
    assert.doesNotMatch(result.stderr, /unexpected run download/);
  } finally {
    rmSync(ghDir, { recursive: true, force: true });
  }
});

test("CLI: --download refuses an artifact whose exe does not match SHA256SUMS", () => {
  const ghDir = fakeGhDir(`
    import { writeFileSync } from "node:fs";
    import { join } from "node:path";
    const argv = process.argv.slice(2);
    if (argv[0] === "run" && argv[1] === "list") {
      process.stdout.write(JSON.stringify([{ databaseId: 8, headSha: "${SHA}", headBranch: "main", event: "push" }]));
      process.exit(0);
    }
    if (argv[0] === "run" && argv[1] === "download") {
      const dir = argv[argv.indexOf("--dir") + 1];
      writeFileSync(join(dir, "ppomi-executor.exe"), "tampered");
      writeFileSync(join(dir, "SHA256SUMS"), "${"f".repeat(64)}  ppomi-executor.exe\\n");
      process.exit(0);
    }
    process.stderr.write("fake gh: unexpected " + argv.join(" ") + "\\n");
    process.exit(9);
  `);
  try {
    const result = runCli(ghDir, ["--download", "--rid", "win-arm64"]);
    assert.equal(result.status, 1, result.stderr);
    assert.match(result.stderr, /does not match SHA256SUMS/);
    assert.doesNotMatch(result.stdout, /staged/);
  } finally {
    rmSync(ghDir, { recursive: true, force: true });
  }
});

test("CLI: --run without a value is a usage error", () => {
  const result = spawnSync(process.execPath, [cli, "--download", "--run"], { encoding: "utf8" });
  assert.equal(result.status, 2);
  assert.match(result.stderr, /--run and --branch need a value/);
});
