import { randomBytes } from "node:crypto";
import {
  KB_STAR_BIZ_ACCOUNT_KEY,
  openOsSecretStore,
  secretEvidence,
  storeKbStarBizAccount,
  SecretStoreError,
  type AccountHandoff,
  type SecretStore,
} from "../../src/index.ts";
import { FakeSecretStore } from "../../src/testing.ts";

const LIVE_KEY = "ppomi/secrets-live-probe";

class FixtureCapture implements AccountHandoff {
  #raw: string | undefined;

  constructor(raw: string | undefined) {
    this.#raw = raw;
  }

  handoff(sink: (accountNumber: string) => void): boolean {
    if (this.#raw === undefined) return false;
    const value = this.#raw;
    this.#raw = undefined;
    sink(value);
    return true;
  }
}

function liveRequested(env: NodeJS.ProcessEnv = process.env): boolean {
  return env.PPOMI_SECRETS_LIVE === "1";
}

function runFixture(): void {
  const store = new FakeSecretStore();
  const evidence = storeKbStarBizAccount(store, new FixtureCapture("001234567890"));
  if (evidence === null || store.get(KB_STAR_BIZ_ACCOUNT_KEY) !== "001234567890") {
    throw new Error("fixture handoff did not store");
  }
  const dumped = JSON.stringify({
    stepId: "store-account",
    observation: { summary: `${evidence.masked} ${evidence.key}` },
  });
  if (dumped.includes("001234567890")) throw new Error("fixture leaked account into evidence");
  process.stdout.write("ppomi-secrets example: PASS\n");
  process.stdout.write("  fixture  FakeSecretStore + AccountCapturePort.handoff shape\n");
  process.stdout.write(`  evidence ${evidence.masked} key=${evidence.key}\n`);
}

function runLive(): "ok" | "skip" {
  const command =
    "PPOMI_SECRETS_LIVE=1 node --experimental-strip-types packages/ppomi-secrets/example/src/main.ts";
  if (!liveRequested()) {
    process.stdout.write("  live     dry-run — fixture only (set PPOMI_SECRETS_LIVE=1 on Mac/Windows)\n");
    process.stdout.write(`           ${command}\n`);
    return "skip";
  }
  if (process.platform !== "darwin" && process.platform !== "win32") {
    process.stdout.write(`  live     SKIP (no Keychain / Credential Manager on ${process.platform})\n`);
    process.stdout.write(`           ${command}\n`);
    return "skip";
  }

  let store: SecretStore;
  try {
    store = openOsSecretStore();
  } catch (error) {
    if (error instanceof SecretStoreError && error.code === "unavailable") {
      process.stdout.write(`  live     SKIP — ${error.message}\n`);
      return "skip";
    }
    throw error;
  }

  const value = `probe-${randomBytes(8).toString("hex")}`;
  try {
    // A crashed earlier probe may have left the dummy item behind; the probe key is never the KB key.
    store.put(LIVE_KEY, value, { overwrite: true });
    const got = store.get(LIVE_KEY);
    if (got !== value) throw new Error("live get mismatch");
    let refused = false;
    try {
      store.put(LIVE_KEY, `${value}-again`);
    } catch (error) {
      refused = error instanceof SecretStoreError && error.code === "exists";
    }
    if (!refused) throw new Error("live put overwrote an existing item without { overwrite: true }");
    const evidence = secretEvidence(LIVE_KEY, value);
    process.stdout.write(`  live     PASS put/get/refuse-overwrite/delete via ${process.platform === "darwin" ? "Keychain" : "Credential Manager"}\n`);
    process.stdout.write(`           key=${evidence.key} masked=${evidence.masked}\n`);
    process.stdout.write("           dummy probe value only — never a real account number\n");
  } finally {
    store.delete(LIVE_KEY);
  }
  return "ok";
}

function main(): void {
  runFixture();
  runLive();
}

main();
