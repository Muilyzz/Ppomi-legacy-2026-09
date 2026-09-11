import {
  KB_STAR_BIZ_ACCOUNT_KEY,
  ClientVault,
  MemoryCiphertextStore,
  acceptDeviceApproval,
  createDeviceKeyPair,
  createVaultKey,
  storeContainsPlaintext,
  vaultEvidence,
} from "../../src/index.ts";

/** Synthetic fixture printed only as a mask. */
const ACCOUNT = "001234567890";
const IDENTITY = "user_stub";

function main(): void {
  const store = new MemoryCiphertextStore();
  const mac = new ClientVault(IDENTITY, createVaultKey(), store);
  const evidence = mac.put(KB_STAR_BIZ_ACCOUNT_KEY, ACCOUNT);

  const winDevice = createDeviceKeyPair();
  const wrapped = mac.approveDevice(winDevice.publicKey);
  const win = new ClientVault(IDENTITY, acceptDeviceApproval(wrapped, winDevice, IDENTITY), store);
  const opened = win.get(KB_STAR_BIZ_ACCOUNT_KEY);
  if (opened !== ACCOUNT) throw new Error("round-trip mismatch");
  if (storeContainsPlaintext(store, ACCOUNT)) throw new Error("store saw plaintext");

  const row = store.snapshot()[0];
  process.stdout.write("ppomi-vault example: PASS\n");
  process.stdout.write(`  hook       MZZ-47 put / MZZ-48 fill  key=${KB_STAR_BIZ_ACCOUNT_KEY}\n`);
  process.stdout.write(`  evidence   ${evidence.masked}\n`);
  process.stdout.write(`  store.box  ${row?.box.length ?? 0} b64 chars  v=${row?.v ?? ""}\n`);
  process.stdout.write(`  fill-mask  ${vaultEvidence(KB_STAR_BIZ_ACCOUNT_KEY, opened).masked}\n`);
  process.stdout.write("  pairing    existing-device approve (QR = same wrap blob later)\n");
}

try {
  main();
} catch (error) {
  const message = error instanceof Error ? error.message : "failed";
  process.stderr.write(`ppomi-vault example: FAIL\n  ${message}\n`);
  process.exitCode = 1;
}
