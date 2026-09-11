import assert from "node:assert/strict";
import { test } from "node:test";
import {
  KB_STAR_BIZ_ACCOUNT_KEY,
  ClientVault,
  MemoryCiphertextStore,
  VAULT_VERSION,
  VaultError,
  acceptDeviceApproval,
  createDeviceKeyPair,
  createVaultKey,
  storeContainsPlaintext,
  vaultEvidence,
} from "../src/index.ts";

/** Synthetic fixture. Not a real account. */
const ACCOUNT = "001234567890";
const IDENTITY = "user_stub";

function macWinRoundTrip(): {
  store: MemoryCiphertextStore;
  win: ClientVault;
  evidence: ReturnType<ClientVault["put"]>;
} {
  const store = new MemoryCiphertextStore();
  const macKey = createVaultKey();
  const mac = new ClientVault(IDENTITY, macKey, store);
  const evidence = mac.put(KB_STAR_BIZ_ACCOUNT_KEY, ACCOUNT);

  const winDevice = createDeviceKeyPair();
  const wrapped = mac.approveDevice(winDevice.publicKey);
  assert.equal(storeContainsPlaintext(store, ACCOUNT), false);
  assert.equal(Buffer.from(wrapped, "base64").includes(Buffer.from(ACCOUNT, "utf8")), false);
  assert.equal(Buffer.from(wrapped, "base64").includes(Buffer.from(macKey)), false);

  const winKey = acceptDeviceApproval(wrapped, winDevice, IDENTITY);
  const win = new ClientVault(IDENTITY, winKey, store);
  return { store, win, evidence };
}

test("Mac put → ciphertext sync → Win get; mock store never sees plaintext", () => {
  const { store, win, evidence } = macWinRoundTrip();
  assert.deepEqual(evidence, { key: KB_STAR_BIZ_ACCOUNT_KEY, masked: "****7890" });
  assert.equal(win.get(KB_STAR_BIZ_ACCOUNT_KEY), ACCOUNT);

  const rows = store.snapshot();
  assert.equal(rows.length, 1);
  assert.equal(rows[0]?.v, VAULT_VERSION);
  assert.equal(rows[0]?.id, KB_STAR_BIZ_ACCOUNT_KEY);
  assert.equal("plaintext" in (rows[0] ?? {}), false);
  assert.equal(storeContainsPlaintext(store, ACCOUNT), false);
  assert.equal(JSON.stringify(rows).includes(ACCOUNT), false);
  assert.equal(JSON.stringify(evidence).includes(ACCOUNT), false);
});

test("mock store refuses a plaintext field or UTF-8 digits as box", () => {
  const store = new MemoryCiphertextStore();
  assert.throws(
    () => store.put({ v: VAULT_VERSION, identityId: IDENTITY, id: KB_STAR_BIZ_ACCOUNT_KEY, box: "x", plaintext: ACCOUNT } as never),
    error => error instanceof VaultError && error.code === "plaintext_rejected",
  );
  assert.throws(
    () =>
      store.put({
        v: VAULT_VERSION,
        identityId: IDENTITY,
        id: KB_STAR_BIZ_ACCOUNT_KEY,
        box: Buffer.concat([Buffer.alloc(12), Buffer.from(ACCOUNT, "utf8"), Buffer.alloc(16)]).toString("base64"),
      }),
    error => error instanceof VaultError && error.code === "plaintext_rejected",
  );
  assert.equal(store.snapshot().length, 0);
});

test("wrong device or tampered box cannot open", () => {
  const store = new MemoryCiphertextStore();
  const mac = new ClientVault(IDENTITY, createVaultKey(), store);
  mac.put(KB_STAR_BIZ_ACCOUNT_KEY, ACCOUNT);
  const stranger = new ClientVault(IDENTITY, createVaultKey(), store);
  assert.throws(
    () => stranger.get(KB_STAR_BIZ_ACCOUNT_KEY),
    error => error instanceof VaultError && error.code === "invalid",
  );

  const row = store.get(IDENTITY, KB_STAR_BIZ_ACCOUNT_KEY);
  assert.ok(row);
  const box = Buffer.from(row.box, "base64");
  box[20] ^= 1;
  store.put({ ...row, box: box.toString("base64") });
  assert.throws(
    () => mac.get(KB_STAR_BIZ_ACCOUNT_KEY),
    error => error instanceof VaultError && error.code === "invalid",
  );
  assert.equal(storeContainsPlaintext(store, ACCOUNT), false);
});

test("put refuses silent overwrite; evidence is mask only", () => {
  const store = new MemoryCiphertextStore();
  const vault = new ClientVault(IDENTITY, createVaultKey(), store);
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
