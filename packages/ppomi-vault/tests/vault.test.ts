import assert from "node:assert/strict";
import { before, test } from "node:test";
import {
  KB_STAR_BIZ_ACCOUNT_KEY,
  ClientVault,
  MemoryCiphertextStore,
  VAULT_VERSION,
  VaultError,
  acceptAuthApproval,
  createAuthRequest,
  createDek,
  minKdfLimits,
  openRecoveryDek,
  persistAuthRequest,
  readyVault,
  storeContainsPlaintext,
  vaultEvidence,
  type RecoveryDekWrapRecord,
} from "../src/index.ts";

/** Synthetic fixtures. Not a real account or recovery secret. */
const ACCOUNT = "001234567890";
const IDENTITY = "user_stub";
const RECOVERY = "ppomi-test-recovery";

before(async () => {
  await readyVault();
});

function macWinRoundTrip(): {
  store: MemoryCiphertextStore;
  win: ClientVault;
  evidence: ReturnType<ClientVault["put"]>;
  dek: Uint8Array;
} {
  const store = new MemoryCiphertextStore();
  const { vault: mac } = ClientVault.firstDevice(IDENTITY, store, RECOVERY, minKdfLimits());
  const recovery = store.get(IDENTITY, "ppomi/vault/dek/recovery");
  assert.ok(recovery && recovery.kind === "dek-recovery");
  const dek = openRecoveryDek(recovery, RECOVERY, minKdfLimits());
  const evidence = mac.put(KB_STAR_BIZ_ACCOUNT_KEY, ACCOUNT);

  const winRequest = createAuthRequest(IDENTITY);
  persistAuthRequest(store, winRequest.public);
  const wrapped = mac.approveAuthRequest(winRequest.public, winRequest.public.fingerprint);
  assert.equal(storeContainsPlaintext(store, ACCOUNT), false);
  assert.equal(storeContainsPlaintext(store, dek), false);
  assert.equal(storeContainsPlaintext(store, RECOVERY), false);
  assert.equal(storeContainsPlaintext(store, winRequest.device.privateKey), false);
  assert.equal(Buffer.from(wrapped, "base64").includes(Buffer.from(ACCOUNT, "utf8")), false);
  assert.equal(Buffer.from(wrapped, "base64").includes(Buffer.from(dek)), false);

  const win = new ClientVault(IDENTITY, acceptAuthApproval(wrapped, winRequest), store);
  return { store, win, evidence, dek };
}

test("Mac put → ciphertext sync → Win get; mock store never sees plaintext", () => {
  const { store, win, evidence, dek } = macWinRoundTrip();
  assert.deepEqual(evidence, { key: KB_STAR_BIZ_ACCOUNT_KEY, masked: "****7890" });
  assert.equal(win.get(KB_STAR_BIZ_ACCOUNT_KEY), ACCOUNT);

  const rows = store.snapshot();
  assert.equal(rows.some(row => row.kind === "payload" && row.id === KB_STAR_BIZ_ACCOUNT_KEY), true);
  assert.equal(rows.some(row => row.kind === "dek-device"), true);
  assert.equal(rows.some(row => row.kind === "dek-recovery"), true);
  assert.equal(rows.some(row => row.kind === "pair-request"), true);
  assert.equal(
    rows.every(row => !("plaintext" in row) && !("dek" in row) && !("privateKey" in row) && !("passphrase" in row)),
    true,
  );
  assert.equal(storeContainsPlaintext(store, ACCOUNT), false);
  assert.equal(storeContainsPlaintext(store, dek), false);
  assert.equal(storeContainsPlaintext(store, RECOVERY), false);
  assert.equal(JSON.stringify(rows).includes(ACCOUNT), false);
  assert.equal(JSON.stringify(evidence).includes(ACCOUNT), false);
  const pair = rows.find(row => row.kind === "pair-request");
  assert.ok(pair && pair.kind === "pair-request");
  assert.match(pair.fingerprint, /^[0-9a-f]{4}(-[0-9a-f]{4}){3}$/);
});

test("mock store refuses a plaintext field or UTF-8 digits as box", () => {
  const store = new MemoryCiphertextStore();
  assert.throws(
    () =>
      store.put({
        kind: "payload",
        v: VAULT_VERSION,
        identityId: IDENTITY,
        id: KB_STAR_BIZ_ACCOUNT_KEY,
        box: "x",
        plaintext: ACCOUNT,
      } as never),
    error => error instanceof VaultError && error.code === "plaintext_rejected",
  );
  assert.throws(
    () =>
      store.put({
        kind: "payload",
        v: VAULT_VERSION,
        identityId: IDENTITY,
        id: KB_STAR_BIZ_ACCOUNT_KEY,
        box: Buffer.concat([Buffer.alloc(24), Buffer.from(ACCOUNT, "utf8"), Buffer.alloc(16)]).toString("base64"),
      }),
    error => error instanceof VaultError && error.code === "plaintext_rejected",
  );
  assert.throws(
    () =>
      store.put({
        kind: "pair-request",
        v: VAULT_VERSION,
        identityId: IDENTITY,
        id: "ppomi/vault/pair/x",
        publicKey: Buffer.alloc(32).toString("base64"),
        fingerprint: "0000-0000-0000-0000",
        expiresAt: Date.now() + 1000,
        privateKey: "secret",
      } as never),
    error => error instanceof VaultError && error.code === "plaintext_rejected",
  );
  assert.equal(store.snapshot().length, 0);
});

test("wrong DEK, wrong fingerprint, or tampered box cannot open", () => {
  const store = new MemoryCiphertextStore();
  const { vault: mac } = ClientVault.firstDevice(IDENTITY, store, RECOVERY, minKdfLimits());
  mac.put(KB_STAR_BIZ_ACCOUNT_KEY, ACCOUNT);
  const stranger = new ClientVault(IDENTITY, createDek(), store);
  assert.throws(
    () => stranger.get(KB_STAR_BIZ_ACCOUNT_KEY),
    error => error instanceof VaultError && error.code === "invalid",
  );

  const winRequest = createAuthRequest(IDENTITY);
  assert.throws(
    () => mac.approveAuthRequest(winRequest.public, "ffff-ffff-ffff-ffff"),
    error => error instanceof VaultError && error.code === "invalid",
  );
  assert.throws(
    () => mac.approveAuthRequest({ ...winRequest.public, expiresAt: Date.now() - 1 }, winRequest.public.fingerprint),
    error => error instanceof VaultError && error.code === "invalid",
  );

  const row = store.get(IDENTITY, KB_STAR_BIZ_ACCOUNT_KEY);
  assert.ok(row && row.kind === "payload");
  const box = Buffer.from(row.box, "base64");
  box[20] ^= 1;
  store.put({ ...row, box: box.toString("base64") });
  assert.throws(
    () => mac.get(KB_STAR_BIZ_ACCOUNT_KEY),
    error => error instanceof VaultError && error.code === "invalid",
  );
  assert.equal(storeContainsPlaintext(store, ACCOUNT), false);
});

test("recovery wrap unwraps on the client; store keeps salt and verifier only", () => {
  const store = new MemoryCiphertextStore();
  const { vault } = ClientVault.firstDevice(IDENTITY, store, RECOVERY, minKdfLimits());
  vault.put(KB_STAR_BIZ_ACCOUNT_KEY, ACCOUNT);
  const row = store.get(IDENTITY, "ppomi/vault/dek/recovery");
  assert.ok(row && row.kind === "dek-recovery");
  const opened = openRecoveryDek(row as RecoveryDekWrapRecord, RECOVERY, minKdfLimits());
  assert.equal(new ClientVault(IDENTITY, opened, store).get(KB_STAR_BIZ_ACCOUNT_KEY), ACCOUNT);
  assert.throws(
    () => openRecoveryDek(row as RecoveryDekWrapRecord, "wrong-passphrase", minKdfLimits()),
    error => error instanceof VaultError && error.code === "invalid",
  );
  assert.equal(storeContainsPlaintext(store, RECOVERY), false);
  assert.equal(storeContainsPlaintext(store, opened), false);
});

test("put refuses silent overwrite; evidence is mask only", () => {
  const store = new MemoryCiphertextStore();
  const { vault } = ClientVault.firstDevice(IDENTITY, store, RECOVERY, minKdfLimits());
  vault.put(KB_STAR_BIZ_ACCOUNT_KEY, ACCOUNT);
  assert.throws(
    () => vault.put(KB_STAR_BIZ_ACCOUNT_KEY, "009876543210"),
    error => error instanceof VaultError && error.code === "exists",
  );
  assert.equal(vault.get(KB_STAR_BIZ_ACCOUNT_KEY), ACCOUNT);
  vault.put(KB_STAR_BIZ_ACCOUNT_KEY, "009876543210", { overwrite: true });
  assert.equal(vault.get(KB_STAR_BIZ_ACCOUNT_KEY), "009876543210");
  assert.deepEqual(vaultEvidence(KB_STAR_BIZ_ACCOUNT_KEY, "009876543210"), {
    key: KB_STAR_BIZ_ACCOUNT_KEY,
    masked: "****3210",
  });
  assert.equal(storeContainsPlaintext(store, ACCOUNT), false);
  assert.equal(storeContainsPlaintext(store, "009876543210"), false);
});
