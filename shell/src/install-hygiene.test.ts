import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { mkdirSync, mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { test } from "node:test";

const repoRoot = join(dirname(fileURLToPath(import.meta.url)), "..", "..");
const script = join(repoRoot, "scripts", "install-shell.sh");

function run(
  args: readonly string[],
  env: NodeJS.ProcessEnv,
): { status: number; stdout: string; stderr: string } {
  const result = spawnSync("sh", [script, ...args], {
    encoding: "utf8",
    env: { ...process.env, SIGN_ID: "", NOTARY_PROFILE: "", ...env },
  });
  return {
    status: result.status ?? 1,
    stdout: result.stdout,
    stderr: result.stderr,
  };
}

function scratch(): { root: string; app: string; dispose: () => void } {
  const root = mkdtempSync(join(tmpdir(), "ppomi-hygiene-"));
  const app = join(root, "Applications", "뽀미.app");
  mkdirSync(dirname(app), { recursive: true });
  return { root, app, dispose: () => rmSync(root, { recursive: true, force: true }) };
}

test("hygiene passes when only the one install path is free", () => {
  const dir = scratch();
  try {
    const result = run(["--hygiene"], { PPOMI_ROOT: dir.root, PPOMI_APP: dir.app });
    assert.equal(result.status, 0, result.stderr);
    assert.match(result.stdout, /hygiene ok/);
  } finally {
    dir.dispose();
  }
});

test("hygiene refuses *-prev.app siblings", () => {
  const dir = scratch();
  try {
    mkdirSync(join(dir.root, "Applications", "뽀미-prev.app"));
    const result = run(["--hygiene"], { PPOMI_ROOT: dir.root, PPOMI_APP: dir.app });
    assert.notEqual(result.status, 0);
    assert.match(result.stderr, /previous|prev/);
  } finally {
    dir.dispose();
  }
});

test("hygiene refuses any *-prev.app or 뽀미*.app sibling by glob, not only the two literal names", () => {
  for (const sibling of ["뽀미 2.app", "뽀미-old.app", "Ppomi copy-prev.app"]) {
    const dir = scratch();
    try {
      mkdirSync(join(dir.root, "Applications", sibling));
      const result = run(["--hygiene"], { PPOMI_ROOT: dir.root, PPOMI_APP: dir.app });
      assert.notEqual(result.status, 0, sibling);
      assert.match(result.stderr, /previous/);
      assert.ok(result.stderr.includes(sibling), result.stderr);
    } finally {
      dir.dispose();
    }
  }
});

test("hygiene accepts the install path itself as the only 뽀미*.app", () => {
  const dir = scratch();
  try {
    mkdirSync(dir.app);
    const result = run(["--hygiene"], { PPOMI_ROOT: dir.root, PPOMI_APP: dir.app });
    assert.equal(result.status, 0, result.stderr);
    assert.match(result.stdout, /hygiene ok/);
  } finally {
    dir.dispose();
  }
});

test("--check rejects a PPOMI_APP that is not an absolute *.app path inside a directory", () => {
  const dir = scratch();
  try {
    for (const bad of [join(dir.root, "Applications"), "/.app", "Applications/뽀미.app", `${dir.root}/Applications/../뽀미.app`]) {
      const result = run(["--check"], { PPOMI_ROOT: dir.root, PPOMI_APP: bad, LOCAL_SIGN_ID: "Apple Development: Test" });
      assert.notEqual(result.status, 0, bad);
      assert.match(result.stderr, /PPOMI_APP must/);
    }
  } finally {
    dir.dispose();
  }
});

test("hygiene refuses dist/backup copies", () => {
  const dir = scratch();
  try {
    mkdirSync(join(dir.root, "dist", "backup"), { recursive: true });
    const result = run(["--hygiene"], { PPOMI_ROOT: dir.root, PPOMI_APP: dir.app });
    assert.notEqual(result.status, 0);
    assert.match(result.stderr, /dist\/backup/);
  } finally {
    dir.dispose();
  }
});

test("--check requires LOCAL_SIGN_ID and rejects ad-hoc-only smoke", () => {
  const dir = scratch();
  try {
    const missing = run(["--check"], { PPOMI_ROOT: dir.root, PPOMI_APP: dir.app, LOCAL_SIGN_ID: "" });
    assert.notEqual(missing.status, 0);
    assert.match(missing.stderr, /LOCAL_SIGN_ID/);
    const ok = run(["--check"], {
      PPOMI_ROOT: dir.root,
      PPOMI_APP: dir.app,
      LOCAL_SIGN_ID: "Apple Development: Test",
    });
    assert.equal(ok.status, 0, ok.stderr);
  } finally {
    dir.dispose();
  }
});
