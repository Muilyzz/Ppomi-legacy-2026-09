import assert from "node:assert/strict";
import { mkdirSync, mkdtempSync, symlinkSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import { NPKI_MAX_DEPTH, defaultNpkiRoot, probeNpki, resolveNpkiRoot } from "../src/index.ts";

/** A throwaway profile: the probe only ever looks under this directory. */
function fakeProfile(): { readonly home: string; readonly npki: string } {
  const home = mkdtempSync(join(tmpdir(), "ppomi-npki-home-"));
  const npki = join(home, "AppData", "LocalLow", "NPKI");
  mkdirSync(npki, { recursive: true });
  return { home, npki };
}

/** Conventional layout: NPKI/<CA>/USER/<DN folder>/<cert file>. Names are opaque placeholders. */
function writeConventionalCert(npki: string, ca: string, dnFolder: string, file: string): string {
  const folder = join(npki, ca, "USER", dnFolder);
  mkdirSync(folder, { recursive: true });
  const target = join(folder, file);
  writeFileSync(target, "not-a-cert");
  return target;
}

test("default root is %USERPROFILE%\\AppData\\LocalLow\\NPKI; off Windows without an override the probe skips", () => {
  const { home } = fakeProfile();
  assert.equal(defaultNpkiRoot({ USERPROFILE: home }), join(home, "AppData", "LocalLow", "NPKI"));
  const skipped = probeNpki({ platform: "linux", env: { USERPROFILE: home } });
  assert.deepEqual(skipped, { status: "skip", root: "default", fileCount: 0, newestMtimeMs: null, truncated: false });
});

test("a missing store is reported as missing, without the path", () => {
  const home = mkdtempSync(join(tmpdir(), "ppomi-npki-nohome-"));
  const missing = probeNpki({ platform: "win32", env: { USERPROFILE: home } });
  assert.equal(missing.status, "missing");
  assert.equal(missing.fileCount, 0);
  assert.equal(JSON.stringify(missing).includes(home), false);
});

test("counts files in the conventional layout; reports count, newest mtime and root source only", () => {
  const { home, npki } = fakeProfile();
  writeConventionalCert(npki, "placeholder-ca", "cn=opaque-dn-folder", "signCert.der");
  writeConventionalCert(npki, "placeholder-ca", "cn=opaque-dn-folder", "signPri.key");
  const sinceMs = Date.now() - 60_000;
  const probed = probeNpki({ platform: "win32", env: { USERPROFILE: home }, sinceMs });
  assert.equal(probed.status, "ok");
  assert.equal(probed.root, "default");
  assert.equal(probed.fileCount, 2);
  assert.equal(probed.newerThanCount, 2);
  assert.equal(probed.truncated, false);
  assert.ok(probed.newestMtimeMs !== null && probed.newestMtimeMs >= sinceMs);
  assert.deepEqual(Object.keys(probed).sort(), ["fileCount", "newerThanCount", "newestMtimeMs", "root", "status", "truncated"]);
  const dumped = JSON.stringify(probed);
  assert.equal(dumped.includes(home), false);
  assert.doesNotMatch(dumped, /signCert|signPri|opaque-dn-folder|placeholder-ca|USER|NPKI/);
});

test("PPOMI_NPKI_ROOT must be an absolute directory strictly under the profile", () => {
  const { home, npki } = fakeProfile();
  const elsewhere = join(home, "Documents", "npki-copy");
  mkdirSync(elsewhere, { recursive: true });
  writeFileSync(join(elsewhere, "copy.der"), "not-a-cert");
  writeConventionalCert(npki, "placeholder-ca", "cn=opaque", "signCert.der");

  const override = probeNpki({ platform: "linux", env: { USERPROFILE: home, PPOMI_NPKI_ROOT: elsewhere } });
  assert.equal(override.status, "ok");
  assert.equal(override.root, "override");
  assert.equal(override.fileCount, 1);
  assert.equal(JSON.stringify(override).includes(elsewhere), false);

  const outside = mkdtempSync(join(tmpdir(), "ppomi-npki-outside-"));
  writeFileSync(join(outside, "outside.der"), "not-a-cert");
  for (const bad of [outside, home, join(home, ".."), "relative/npki", ""]) {
    const resolution = resolveNpkiRoot(bad, { USERPROFILE: home });
    if (bad === "") {
      assert.equal(resolution.kind, "default");
      continue;
    }
    assert.equal(resolution.kind, "refused", `expected refusal for ${bad === home ? "<home>" : bad === outside ? "<outside>" : bad}`);
    const probed = probeNpki({ platform: "win32", env: { USERPROFILE: home, PPOMI_NPKI_ROOT: bad } });
    assert.equal(probed.status, "refused");
    assert.equal(probed.fileCount, 0);
    assert.equal(probed.root, "override");
  }
  assert.equal(probeNpki({ platform: "win32", root: outside, env: { USERPROFILE: home } }).status, "refused");
});

test("links are never followed: a linked directory or a linked root contributes nothing", () => {
  const { home, npki } = fakeProfile();
  const outside = mkdtempSync(join(tmpdir(), "ppomi-npki-linktarget-"));
  writeFileSync(join(outside, "behind-link.der"), "not-a-cert");
  writeConventionalCert(npki, "placeholder-ca", "cn=opaque", "signCert.der");
  const linkType = process.platform === "win32" ? "junction" : "dir";
  symlinkSync(outside, join(npki, "linked"), linkType);
  try {
    symlinkSync(join(outside, "behind-link.der"), join(npki, "linked-file.der"));
  } catch {
    // File symlinks need a privilege on Windows; the directory link above already covers the rule.
  }

  const probed = probeNpki({ platform: "win32", env: { USERPROFILE: home } });
  assert.equal(probed.status, "ok");
  assert.equal(probed.fileCount, 1);

  const linkedRoot = join(home, "npki-link");
  symlinkSync(npki, linkedRoot, linkType);
  assert.equal(probeNpki({ platform: "win32", env: { USERPROFILE: home, PPOMI_NPKI_ROOT: linkedRoot } }).status, "refused");
});

test("the walk is bounded: depth cap keeps the conventional files and drops deeper ones; entry cap reports truncated", () => {
  const { home, npki } = fakeProfile();
  assert.equal(NPKI_MAX_DEPTH, 3);
  writeConventionalCert(npki, "placeholder-ca", "cn=opaque", "signCert.der");
  const tooDeep = join(npki, "a", "b", "c", "d");
  mkdirSync(tooDeep, { recursive: true });
  writeFileSync(join(tooDeep, "deep.der"), "not-a-cert");
  writeFileSync(join(npki, "top-level.der"), "not-a-cert");

  const probed = probeNpki({ platform: "win32", env: { USERPROFILE: home } });
  assert.equal(probed.fileCount, 2);
  assert.equal(probed.truncated, false);

  const capped = probeNpki({ platform: "win32", env: { USERPROFILE: home }, maxEntries: 2 });
  assert.equal(capped.status, "ok");
  assert.equal(capped.truncated, true);
  assert.ok(capped.fileCount <= 2);
});
