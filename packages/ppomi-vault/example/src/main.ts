import {
  KB_STAR_BIZ_ACCOUNT_KEY,
  ClientVault,
  MemoryCiphertextStore,
  acceptAuthApproval,
  createAuthRequest,
  interactiveKdfLimits,
  pairRequestKeyId,
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
  // Example runs at the INTERACTIVE floor; omit the argument in production for MODERATE.
  const { vault: mac } = ClientVault.firstDevice(IDENTITY, store, RECOVERY, interactiveKdfLimits());
  const evidence = mac.put(KB_STAR_BIZ_ACCOUNT_KEY, ACCOUNT);

  // Win: one-time keypair; only pubkey + expiry go to the store. The fingerprint is on the Win screen.
  const winRequest = createAuthRequest(IDENTITY);
  persistAuthRequest(store, winRequest.public);
  const shownOnWin = winRequest.fingerprint;

  // Mac: read the request from the store, ask the person for the phrase on the Win screen, then approve.
  const relayed = store.get(IDENTITY, pairRequestKeyId(winRequest.public.requestId));
  if (relayed?.kind !== "pair-request") throw new Error("pairing request missing");
  const typedOnMac = shownOnWin; // out-of-band: the person reads Win's screen and types it on the Mac
  const wrapped = mac.approveAuthRequest(
    { ...winRequest.public, publicKey: Buffer.from(relayed.publicKey, "base64") },
    typedOnMac,
  );
  const shownOnMac = mac.deviceFingerprint();

  // Win: the person reads the Mac's phrase; the wrap must come from that key.
  const typedOnWin = shownOnMac; // out-of-band, other direction
  const win = new ClientVault(IDENTITY, acceptAuthApproval(wrapped, winRequest, typedOnWin), store);
  const opened = win.get(KB_STAR_BIZ_ACCOUNT_KEY);
  if (opened !== ACCOUNT) throw new Error("round-trip mismatch");
  if (storeContainsPlaintext(store, ACCOUNT) || storeContainsPlaintext(store, RECOVERY)) {
    throw new Error("store saw plaintext");
  }

  const payload = store.snapshot().find(row => row.kind === "payload");
  process.stdout.write("ppomi-vault example: PASS\n");
  process.stdout.write(`  hook        MZZ-47 put / MZZ-48 fill  key=${KB_STAR_BIZ_ACCOUNT_KEY}\n`);
  process.stdout.write(`  evidence    ${evidence.masked}\n`);
  process.stdout.write(
    `  store.box   ${payload && "box" in payload ? payload.box.length : 0} b64 chars  v=${payload?.v ?? ""}  seq=${payload?.kind === "payload" ? payload.seq : "-"}\n`,
  );
  process.stdout.write(`  fill-mask   ${vaultEvidence(KB_STAR_BIZ_ACCOUNT_KEY, opened).masked}\n`);
  process.stdout.write(`  win phrase  ${shownOnWin}  (Win screen → typed on Mac)\n`);
  process.stdout.write(`  mac phrase  ${shownOnMac}  (Mac screen → typed on Win)\n`);
  process.stdout.write("  pairing     existing-device approve, both phrases out-of-band, wrap authenticated (QR out)\n");
}

main().catch(error => {
  const message = error instanceof Error ? error.message : "failed";
  process.stderr.write(`ppomi-vault example: FAIL\n  ${message}\n`);
  process.exitCode = 1;
});
