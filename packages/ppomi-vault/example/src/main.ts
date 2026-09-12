import {
  KB_STAR_BIZ_ACCOUNT_KEY,
  ClientVault,
  MemoryCiphertextStore,
  acceptAuthApproval,
  createAuthRequest,
  minKdfLimits,
  persistAuthRequest,
  readyVault,
  storeContainsPlaintext,
  vaultEvidence,
} from "../../src/index.ts";

/** Synthetic fixtures printed only as a mask / fingerprint. */
const ACCOUNT = "001234567890";
const IDENTITY = "user_stub";
const RECOVERY = "ppomi-test-recovery";

async function main(): Promise<void> {
  await readyVault();
  const store = new MemoryCiphertextStore();
  const { vault: mac } = ClientVault.firstDevice(IDENTITY, store, RECOVERY, minKdfLimits());
  const evidence = mac.put(KB_STAR_BIZ_ACCOUNT_KEY, ACCOUNT);

  const winRequest = createAuthRequest(IDENTITY);
  persistAuthRequest(store, winRequest.public);
  const wrapped = mac.approveAuthRequest(winRequest.public, winRequest.public.fingerprint);
  const win = new ClientVault(IDENTITY, acceptAuthApproval(wrapped, winRequest), store);
  const opened = win.get(KB_STAR_BIZ_ACCOUNT_KEY);
  if (opened !== ACCOUNT) throw new Error("round-trip mismatch");
  if (storeContainsPlaintext(store, ACCOUNT) || storeContainsPlaintext(store, RECOVERY)) {
    throw new Error("store saw plaintext");
  }

  const payload = store.snapshot().find(row => row.kind === "payload");
  process.stdout.write("ppomi-vault example: PASS\n");
  process.stdout.write(`  hook       MZZ-47 put / MZZ-48 fill  key=${KB_STAR_BIZ_ACCOUNT_KEY}\n`);
  process.stdout.write(`  evidence   ${evidence.masked}\n`);
  process.stdout.write(`  store.box  ${payload && "box" in payload ? payload.box.length : 0} b64 chars  v=${payload?.v ?? ""}\n`);
  process.stdout.write(`  fill-mask  ${vaultEvidence(KB_STAR_BIZ_ACCOUNT_KEY, opened).masked}\n`);
  process.stdout.write(`  fingerprint ${winRequest.public.fingerprint}\n`);
  process.stdout.write("  pairing    existing-device approve + fingerprint (QR out)\n");
}

main().catch(error => {
  const message = error instanceof Error ? error.message : "failed";
  process.stderr.write(`ppomi-vault example: FAIL\n  ${message}\n`);
  process.exitCode = 1;
});
