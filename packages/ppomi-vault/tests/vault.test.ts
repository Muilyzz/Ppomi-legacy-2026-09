import assert from "node:assert/strict";
import { inspect } from "node:util";
import { before, test } from "node:test";
import {
  KB_STAR_BIZ_ACCOUNT_KEY,
  RESERVED_KEY_PREFIX,
  ClientVault,
  DEVICE_WRAP_LEN,
  MemoryCiphertextStore,
  VAULT_VERSION,
  VaultError,
  acceptAuthApproval,
  createAuthRequest,
  createDek,
  createDeviceKeyPair,
  defaultKdfLimits,
  deviceWrapKeyId,
  interactiveKdfLimits,
  openDeviceDek,
  openRecoveryDek,
  pairRequestKeyId,
  pairingFingerprint,
  persistAuthRequest,
  readyVault,
  storeContainsPlaintext,
  vaultEvidence,
  wrapDekForDevice,
  type DeviceDekWrapRecord,
  type PayloadRecord,
  type RecoveryDekWrapRecord,
} from "../src/index.ts";

/** Synthetic fixtures. Not a real account or recovery secret. */
const ACCOUNT = "001234567890";
const OTHER = "009876543210";
const IDENTITY = "user_stub";
const RECOVERY = "ppomi-test-recovery";
const RECOVERY_ROW = `${RESERVED_KEY_PREFIX}dek/recovery`;

before(async () => {
  await readyVault();
});

function isCode(code: VaultError["code"]): (error: unknown) => boolean {
  return (error: unknown) => error instanceof VaultError && error.code === code;
}

/** Tests wrap at the INTERACTIVE floor (≈0.1 s); the production default is MODERATE. */
function firstDevice(store: MemoryCiphertextStore): ReturnType<typeof ClientVault.firstDevice> {
  return ClientVault.firstDevice(IDENTITY, store, RECOVERY, interactiveKdfLimits());
}

function payloadRow(store: MemoryCiphertextStore, keyId: string): PayloadRecord {
  const row = store.get(IDENTITY, keyId);
  assert.ok(row && row.kind === "payload");
  return row;
}

/**
 * Mac put → Win pairs → Win get. The two fingerprints travel by voice/eyes, never
 * through the store: Win's from Win's screen to the Mac, the Mac's from the Mac's
 * screen to Win.
 */
function macWinRoundTrip(): {
  store: MemoryCiphertextStore;
  mac: ClientVault;
  win: ClientVault;
  evidence: ReturnType<ClientVault["put"]>;
  dek: Uint8Array;
} {
  const store = new MemoryCiphertextStore();
  const { vault: mac, device: macDevice } = firstDevice(store);
  const recovery = store.get(IDENTITY, RECOVERY_ROW);
  assert.ok(recovery && recovery.kind === "dek-recovery");
  const dek = openRecoveryDek(recovery, RECOVERY);
  const evidence = mac.put(KB_STAR_BIZ_ACCOUNT_KEY, ACCOUNT);

  const winRequest = createAuthRequest(IDENTITY);
  persistAuthRequest(store, winRequest.public);
  const spokenWinFingerprint = winRequest.fingerprint; // read off the Win screen
  const relayed = store.get(IDENTITY, pairRequestKeyId(winRequest.public.requestId));
  assert.ok(relayed && relayed.kind === "pair-request");
  assert.equal("fingerprint" in relayed, false);
  const wrapped = mac.approveAuthRequest(
    { ...winRequest.public, publicKey: Buffer.from(relayed.publicKey, "base64") },
    spokenWinFingerprint,
  );
  const spokenMacFingerprint = mac.deviceFingerprint(); // read off the Mac screen
  assert.equal(spokenMacFingerprint, pairingFingerprint(macDevice.publicKey));

  assert.equal(storeContainsPlaintext(store, ACCOUNT), false);
  assert.equal(storeContainsPlaintext(store, dek), false);
  assert.equal(storeContainsPlaintext(store, RECOVERY), false);
  assert.equal(storeContainsPlaintext(store, winRequest.device.privateKey), false);
  assert.equal(storeContainsPlaintext(store, macDevice.privateKey), false);
  assert.equal(Buffer.from(wrapped, "base64").includes(Buffer.from(ACCOUNT, "utf8")), false);
  assert.equal(Buffer.from(wrapped, "base64").includes(Buffer.from(dek)), false);

  const win = new ClientVault(IDENTITY, acceptAuthApproval(wrapped, winRequest, spokenMacFingerprint), store);
  return { store, mac, win, evidence, dek };
}

test("Mac put → ciphertext sync → Win get; mock store never sees plaintext or a fingerprint", () => {
  const { store, win, evidence, dek } = macWinRoundTrip();
  assert.deepEqual(evidence, { key: KB_STAR_BIZ_ACCOUNT_KEY, masked: "****7890" });
  assert.equal(win.get(KB_STAR_BIZ_ACCOUNT_KEY), ACCOUNT);

  const rows = store.snapshot();
  assert.equal(rows.some(row => row.kind === "payload" && row.id === KB_STAR_BIZ_ACCOUNT_KEY && row.seq === 1), true);
  assert.equal(rows.some(row => row.kind === "dek-device" && row.id.startsWith(`${RESERVED_KEY_PREFIX}dek/device/`)), true);
  assert.equal(rows.some(row => row.kind === "dek-device" && row.id.startsWith(`${RESERVED_KEY_PREFIX}dek/pair/`)), true);
  assert.equal(rows.some(row => row.kind === "dek-recovery"), true);
  assert.equal(rows.some(row => row.kind === "pair-request"), false, "pairing request consumed on approve");
  assert.equal(
    rows.every(row => !("plaintext" in row) && !("dek" in row) && !("privateKey" in row) && !("fingerprint" in row)),
    true,
  );
  assert.equal(storeContainsPlaintext(store, ACCOUNT), false);
  assert.equal(storeContainsPlaintext(store, dek), false);
  assert.equal(JSON.stringify(rows).includes(ACCOUNT), false);
  assert.equal(JSON.stringify(evidence).includes(ACCOUNT), false);
});

test("store operator swaps the pairing pubkey: approval refused, DEK never sealed", () => {
  const store = new MemoryCiphertextStore();
  const { vault: mac } = firstDevice(store);
  const winRequest = createAuthRequest(IDENTITY);
  persistAuthRequest(store, winRequest.public);
  const spokenWinFingerprint = winRequest.fingerprint;

  const operator = createAuthRequest(IDENTITY); // the store's own keypair
  const swapped = { ...winRequest.public, publicKey: operator.public.publicKey };
  assert.notEqual(pairingFingerprint(swapped.publicKey), spokenWinFingerprint);

  assert.throws(() => mac.approveAuthRequest(swapped, spokenWinFingerprint), isCode("fingerprint_mismatch"));
  assert.equal(store.get(IDENTITY, `${RESERVED_KEY_PREFIX}dek/pair/${winRequest.public.requestId}`), undefined);
  assert.ok(store.get(IDENTITY, pairRequestKeyId(winRequest.public.requestId)), "request not consumed");
  assert.equal(store.snapshot().filter(row => row.kind === "dek-device").length, 1, "only the Mac self-wrap exists");

  // The store relays no fingerprint the operator could make consistent with its key (see the store test).
  assert.throws(() => mac.approveAuthRequest(winRequest.public, "ffff-ffff-ffff-ffff"), isCode("fingerprint_mismatch"));
  assert.throws(
    () => mac.approveAuthRequest({ ...winRequest.public, expiresAt: Date.now() - 1 }, spokenWinFingerprint),
    isCode("expired"),
  );
});

test("store operator mints its own DEK wrap: Win refuses it (sender fingerprint), wrong device cannot open", () => {
  const store = new MemoryCiphertextStore();
  const { vault: mac } = firstDevice(store);
  const winRequest = createAuthRequest(IDENTITY);
  const spokenMacFingerprint = mac.deviceFingerprint();

  const operatorDevice = createDeviceKeyPair();
  const operatorWrap = Buffer.from(wrapDekForDevice(createDek(), winRequest.public.publicKey, operatorDevice)).toString(
    "base64",
  );
  assert.throws(() => acceptAuthApproval(operatorWrap, winRequest, spokenMacFingerprint), isCode("fingerprint_mismatch"));

  const genuine = mac.approveAuthRequest(winRequest.public, winRequest.fingerprint);
  assert.equal(Buffer.from(genuine, "base64").byteLength, DEVICE_WRAP_LEN);
  assert.throws(() => acceptAuthApproval(genuine, createAuthRequest(IDENTITY), spokenMacFingerprint), isCode("invalid"));
  assert.throws(() => acceptAuthApproval(genuine, winRequest, pairingFingerprint(operatorDevice.publicKey)), isCode("fingerprint_mismatch"));

  const tampered = Buffer.from(genuine, "base64");
  tampered[tampered.length - 1] ^= 1;
  assert.throws(() => acceptAuthApproval(tampered.toString("base64"), winRequest, spokenMacFingerprint), isCode("invalid"));

  const dek = acceptAuthApproval(genuine, winRequest, spokenMacFingerprint);
  assert.equal(dek.byteLength, 32);
});

test("first device self-wrap opens with the device key (daily unlock) and is one row per device", () => {
  const store = new MemoryCiphertextStore();
  const { vault, device } = firstDevice(store);
  vault.put(KB_STAR_BIZ_ACCOUNT_KEY, ACCOUNT);
  const row = store.get(IDENTITY, deviceWrapKeyId(device.publicKey));
  assert.ok(row && row.kind === "dek-device");
  const dek = openDeviceDek(row as DeviceDekWrapRecord, device, vault.deviceFingerprint());
  assert.equal(new ClientVault(IDENTITY, dek, store).get(KB_STAR_BIZ_ACCOUNT_KEY), ACCOUNT);
  assert.throws(() => openDeviceDek(row as DeviceDekWrapRecord, createDeviceKeyPair(), vault.deviceFingerprint()), isCode("invalid"));
  assert.notEqual(deviceWrapKeyId(device.publicKey), deviceWrapKeyId(createDeviceKeyPair().publicKey));
});

test("AuthRequest and DeviceKeyPair serialize without private key bytes", () => {
  const request = createAuthRequest(IDENTITY);
  const privateBytes = Buffer.from(request.device.privateKey);
  for (const text of [JSON.stringify(request), JSON.stringify(request.device), inspect(request), inspect(request.device)]) {
    assert.equal(text.includes("privateKey"), false, text);
    assert.equal(text.includes(privateBytes.toString("base64")), false);
    assert.equal(text.includes(privateBytes.toString("hex")), false);
    assert.equal(text.includes(`"0":${privateBytes[0]},"1":${privateBytes[1]}`), false);
  }
  const json = JSON.parse(JSON.stringify(request)) as { public: { publicKey: string }; fingerprint: string };
  assert.equal(json.public.publicKey, Buffer.from(request.public.publicKey).toString("base64"));
  assert.equal(json.fingerprint, request.fingerprint);
  assert.match(request.fingerprint, /^[0-9a-f]{4}(-[0-9a-f]{4}){3}$/);
});

test("mock store refuses plaintext-ish fields, bare digits as box, a fingerprint column, and kind changes", () => {
  const store = new MemoryCiphertextStore();
  const payload = { kind: "payload", v: VAULT_VERSION, identityId: IDENTITY, id: KB_STAR_BIZ_ACCOUNT_KEY, seq: 1 } as const;
  assert.throws(() => store.put({ ...payload, box: "x", plaintext: ACCOUNT } as never), isCode("plaintext_rejected"));
  assert.throws(
    () =>
      store.put({
        ...payload,
        box: Buffer.concat([Buffer.alloc(24), Buffer.from(ACCOUNT, "utf8"), Buffer.alloc(16)]).toString("base64"),
      }),
    isCode("plaintext_rejected"),
  );
  assert.throws(() => store.put({ ...payload, seq: 0, box: Buffer.alloc(41).toString("base64") }), isCode("plaintext_rejected"));
  assert.throws(
    () =>
      store.put({
        kind: "pair-request",
        v: VAULT_VERSION,
        identityId: IDENTITY,
        id: "ppomi/vault/pair/x",
        publicKey: Buffer.alloc(32).toString("base64"),
        expiresAt: Date.now() + 1000,
        fingerprint: "0000-0000-0000-0000",
      } as never),
    isCode("plaintext_rejected"),
  );
  assert.throws(
    () =>
      store.put({
        kind: "pair-request",
        v: VAULT_VERSION,
        identityId: IDENTITY,
        id: "ppomi/vault/pair/x",
        publicKey: Buffer.alloc(31).toString("base64"),
        expiresAt: Date.now() + 1000,
      }),
    isCode("plaintext_rejected"),
  );
  assert.equal(store.snapshot().length, 0);

  const { vault } = firstDevice(store);
  vault.put(KB_STAR_BIZ_ACCOUNT_KEY, ACCOUNT);
  assert.throws(
    () =>
      store.put({
        kind: "dek-device",
        v: VAULT_VERSION,
        identityId: IDENTITY,
        id: KB_STAR_BIZ_ACCOUNT_KEY,
        box: Buffer.alloc(DEVICE_WRAP_LEN).toString("base64"),
      }),
    isCode("invalid"),
    "row kind cannot change",
  );
});

test("wrong DEK or a flipped nonce, ciphertext, or tag byte cannot open", () => {
  const store = new MemoryCiphertextStore();
  const { vault: mac } = firstDevice(store);
  mac.put(KB_STAR_BIZ_ACCOUNT_KEY, ACCOUNT);
  const stranger = new ClientVault(IDENTITY, createDek(), store);
  assert.throws(() => stranger.get(KB_STAR_BIZ_ACCOUNT_KEY), isCode("invalid"));

  const row = payloadRow(store, KB_STAR_BIZ_ACCOUNT_KEY);
  const box = Buffer.from(row.box, "base64");
  assert.equal(box.byteLength, 24 + Buffer.byteLength(ACCOUNT) + 16);
  // nonce byte, ciphertext byte, tag byte — same seq, so only the tamper can fail the open
  for (const index of [20, 24 + 3, box.byteLength - 1]) {
    const tampered = Buffer.from(box);
    tampered[index] ^= 1;
    store.delete(IDENTITY, KB_STAR_BIZ_ACCOUNT_KEY);
    store.put({ ...row, box: tampered.toString("base64") });
    assert.throws(() => mac.get(KB_STAR_BIZ_ACCOUNT_KEY), isCode("invalid"), `byte ${index}`);
  }
  store.delete(IDENTITY, KB_STAR_BIZ_ACCOUNT_KEY);
  store.put(row);
  assert.equal(mac.get(KB_STAR_BIZ_ACCOUNT_KEY), ACCOUNT);
  assert.equal(storeContainsPlaintext(store, ACCOUNT), false);
});

test("seq is monotonic and bound into the AAD: stale writes, re-labelled envelopes, and rollbacks are refused", () => {
  const store = new MemoryCiphertextStore();
  const { vault } = firstDevice(store);
  vault.put(KB_STAR_BIZ_ACCOUNT_KEY, ACCOUNT);
  const first = payloadRow(store, KB_STAR_BIZ_ACCOUNT_KEY);
  vault.put(KB_STAR_BIZ_ACCOUNT_KEY, OTHER, { overwrite: true });
  const second = payloadRow(store, KB_STAR_BIZ_ACCOUNT_KEY);
  assert.equal(first.seq, 1);
  assert.equal(second.seq, 2);

  assert.throws(() => store.put(first), isCode("stale"));
  assert.throws(() => store.put({ ...second, seq: 2 }), isCode("stale"));
  assert.equal(payloadRow(store, KB_STAR_BIZ_ACCOUNT_KEY).seq, 2);
});

test("rollback: a client that saw seq 2 refuses a served seq 1; a re-labelled seq fails the AAD", () => {
  const store = new MemoryCiphertextStore();
  const { vault } = firstDevice(store);
  vault.put(KB_STAR_BIZ_ACCOUNT_KEY, ACCOUNT);
  const first = payloadRow(store, KB_STAR_BIZ_ACCOUNT_KEY);
  vault.put(KB_STAR_BIZ_ACCOUNT_KEY, OTHER, { overwrite: true });
  assert.equal(vault.get(KB_STAR_BIZ_ACCOUNT_KEY), OTHER);

  const rewound = new MemoryCiphertextStore();
  rewound.put(first);
  const rewoundVault = new ClientVault(IDENTITY, openRecoveryDek(recoveryOf(store), RECOVERY), rewound);
  assert.equal(rewoundVault.get(KB_STAR_BIZ_ACCOUNT_KEY), ACCOUNT, "a fresh process has no history and reads it");

  store.delete(IDENTITY, KB_STAR_BIZ_ACCOUNT_KEY);
  store.put(first);
  assert.throws(() => vault.get(KB_STAR_BIZ_ACCOUNT_KEY), isCode("rollback"));

  store.delete(IDENTITY, KB_STAR_BIZ_ACCOUNT_KEY);
  store.put({ ...first, seq: 3 });
  assert.throws(() => vault.get(KB_STAR_BIZ_ACCOUNT_KEY), isCode("invalid"), "seq is in the AAD");

  const other = new MemoryCiphertextStore();
  const { vault: a } = firstDevice(other);
  a.put(KB_STAR_BIZ_ACCOUNT_KEY, ACCOUNT);
  a.put("ppomi/kb-star-biz/other", OTHER);
  const rowA = payloadRow(other, KB_STAR_BIZ_ACCOUNT_KEY);
  other.delete(IDENTITY, "ppomi/kb-star-biz/other");
  other.put({ ...rowA, id: "ppomi/kb-star-biz/other" });
  assert.throws(() => a.get("ppomi/kb-star-biz/other"), isCode("invalid"), "key id is in the AAD");
});

test("payload API cannot touch the reserved ppomi/vault/ namespace; delete removes a payload", () => {
  const store = new MemoryCiphertextStore();
  const { vault } = firstDevice(store);
  assert.throws(() => vault.put(RECOVERY_ROW, "1234"), isCode("invalid_key"));
  assert.throws(() => vault.put(RECOVERY_ROW, "1234", { overwrite: true }), isCode("invalid_key"));
  assert.throws(() => vault.get(RECOVERY_ROW), isCode("invalid_key"));
  assert.throws(() => vault.delete(RECOVERY_ROW), isCode("invalid_key"));
  assert.throws(() => vaultEvidence(`${RESERVED_KEY_PREFIX}x`, "1234"), isCode("invalid_key"));
  assert.equal(store.get(IDENTITY, RECOVERY_ROW)?.kind, "dek-recovery");

  vault.put(KB_STAR_BIZ_ACCOUNT_KEY, ACCOUNT);
  vault.delete(KB_STAR_BIZ_ACCOUNT_KEY);
  assert.equal(vault.get(KB_STAR_BIZ_ACCOUNT_KEY), undefined);
  vault.put(KB_STAR_BIZ_ACCOUNT_KEY, OTHER);
  assert.equal(payloadRow(store, KB_STAR_BIZ_ACCOUNT_KEY).seq, 2, "sequence continues after delete");
  assert.equal(vault.get(KB_STAR_BIZ_ACCOUNT_KEY), OTHER);
});

test("recovery wrap: parameters travel with the record, MODERATE by default, nothing below INTERACTIVE", () => {
  const store = new MemoryCiphertextStore();
  const { vault } = ClientVault.firstDevice(IDENTITY, store, RECOVERY);
  vault.put(KB_STAR_BIZ_ACCOUNT_KEY, ACCOUNT);
  const row = recoveryOf(store);
  assert.deepEqual(row.kdf, { alg: "argon2id13", ...defaultKdfLimits() });
  assert.ok(row.kdf.opsLimit >= 3 && row.kdf.memLimit >= 256 * 1024 * 1024, "MODERATE");
  assert.equal(Object.keys(row).sort().join(","), "box,id,identityId,kdf,kind,salt,v,verifier");

  const opened = openRecoveryDek(row, RECOVERY);
  assert.equal(new ClientVault(IDENTITY, opened, store).get(KB_STAR_BIZ_ACCOUNT_KEY), ACCOUNT);
  assert.throws(() => openRecoveryDek(row, "wrong-passphrase"), isCode("invalid"));
  assert.throws(() => openRecoveryDek({ ...row, kdf: { ...row.kdf, memLimit: 8192 } }, RECOVERY), isCode("weak_kdf"));
  assert.throws(
    () => ClientVault.firstDevice(IDENTITY, new MemoryCiphertextStore(), RECOVERY, { opsLimit: 1, memLimit: 8192 }),
    isCode("weak_kdf"),
  );
  assert.throws(
    () => store.put({ ...row, id: `${RESERVED_KEY_PREFIX}dek/recovery-weak`, kdf: { ...row.kdf, opsLimit: 1 } }),
    isCode("weak_kdf"),
  );
  assert.equal(storeContainsPlaintext(store, RECOVERY), false);
  assert.equal(storeContainsPlaintext(store, opened), false);
});

test("put refuses silent overwrite; evidence is mask only", () => {
  const store = new MemoryCiphertextStore();
  const { vault } = firstDevice(store);
  vault.put(KB_STAR_BIZ_ACCOUNT_KEY, ACCOUNT);
  assert.throws(() => vault.put(KB_STAR_BIZ_ACCOUNT_KEY, OTHER), isCode("exists"));
  assert.equal(vault.get(KB_STAR_BIZ_ACCOUNT_KEY), ACCOUNT);
  vault.put(KB_STAR_BIZ_ACCOUNT_KEY, OTHER, { overwrite: true });
  assert.equal(vault.get(KB_STAR_BIZ_ACCOUNT_KEY), OTHER);
  assert.deepEqual(vaultEvidence(KB_STAR_BIZ_ACCOUNT_KEY, OTHER), { key: KB_STAR_BIZ_ACCOUNT_KEY, masked: "****3210" });
  assert.equal(storeContainsPlaintext(store, ACCOUNT), false);
  assert.equal(storeContainsPlaintext(store, OTHER), false);
});

function recoveryOf(store: MemoryCiphertextStore): RecoveryDekWrapRecord {
  const row = store.get(IDENTITY, RECOVERY_ROW);
  assert.ok(row && row.kind === "dek-recovery");
  return row;
}
