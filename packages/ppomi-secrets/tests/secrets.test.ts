import assert from "node:assert/strict";
import { test } from "node:test";
import {
  CredentialManagerSecretStore,
  FakeSecretStore,
  KB_STAR_BIZ_ACCOUNT_KEY,
  KeychainSecretStore,
  SecretStoreError,
  openOsSecretStore,
  secretEvidence,
  storeKbStarBizAccount,
  type AccountHandoff,
  type SecretExec,
  type SecretExecResult,
} from "../src/index.ts";

const ACCOUNT = "001234567890";

function scripted(
  handler: (command: string, args: readonly string[], extraEnv?: Readonly<Record<string, string>>) => SecretExecResult,
): SecretExec {
  return handler;
}

class OnceCapture implements AccountHandoff {
  #raw: string | undefined;

  constructor(raw: string) {
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

test("fake store put/get/delete and rejects bad keys", () => {
  const store = new FakeSecretStore();
  store.put(KB_STAR_BIZ_ACCOUNT_KEY, ACCOUNT);
  assert.equal(store.get(KB_STAR_BIZ_ACCOUNT_KEY), ACCOUNT);
  store.delete(KB_STAR_BIZ_ACCOUNT_KEY);
  assert.equal(store.get(KB_STAR_BIZ_ACCOUNT_KEY), undefined);
  store.delete(KB_STAR_BIZ_ACCOUNT_KEY);

  assert.throws(() => store.put("kb-account", ACCOUNT), (error: unknown) => {
    return error instanceof SecretStoreError && error.code === "invalid_key";
  });
  assert.throws(() => store.put("ppomi/../etc", ACCOUNT), (error: unknown) => {
    return error instanceof SecretStoreError && error.code === "invalid_key";
  });
  assert.throws(() => store.put(KB_STAR_BIZ_ACCOUNT_KEY, ""), (error: unknown) => {
    return error instanceof SecretStoreError && error.code === "invalid_value";
  });
});

test("KB handoff stores once; StepResult evidence is masked + key only", () => {
  const store = new FakeSecretStore();
  const capture = new OnceCapture(ACCOUNT);
  const evidence = storeKbStarBizAccount(store, capture);
  assert.deepEqual(evidence, { masked: "****7890", key: KB_STAR_BIZ_ACCOUNT_KEY });
  assert.equal(store.get(KB_STAR_BIZ_ACCOUNT_KEY), ACCOUNT);
  assert.equal(storeKbStarBizAccount(store, capture), null);

  const stepResult = {
    stepId: "store-account",
    playbookId: "kb-star-biz-iphone",
    driver: "phone",
    action: "read",
    status: "ok",
    attempt: "executed",
    target: { kind: "none" },
    observation: { summary: `${evidence!.masked} ${evidence!.key}` },
    timingMs: 1,
  };
  const dumped = JSON.stringify(stepResult);
  assert.equal(dumped.includes(ACCOUNT), false);
  assert.equal(dumped.includes("001234"), false);
  assert.equal(dumped.includes("****7890"), true);
  assert.equal(dumped.includes(KB_STAR_BIZ_ACCOUNT_KEY), true);
  assert.deepEqual(Object.keys(evidence!), ["masked", "key"]);
});

test("secretEvidence never carries the raw value", () => {
  const evidence = secretEvidence("ppomi/secrets-live-probe", ACCOUNT);
  assert.equal(JSON.stringify(evidence).includes(ACCOUNT), false);
  assert.equal(evidence.masked, "****7890");
});

test("KeychainSecretStore talks to security with the secret only as -w argv", () => {
  const calls: { command: string; args: readonly string[] }[] = [];
  let stored: string | undefined;
  const store = new KeychainSecretStore(
    scripted((command, args) => {
      calls.push({ command, args });
      if (args[0] === "add-generic-password") {
        stored = args[args.indexOf("-w") + 1];
        return { status: 0, stdout: "", stderr: "" };
      }
      if (args[0] === "find-generic-password") {
        if (stored === undefined) return { status: 44, stdout: "", stderr: "not found" };
        return { status: 0, stdout: `${stored}\n`, stderr: "" };
      }
      if (args[0] === "delete-generic-password") {
        stored = undefined;
        return { status: 44, stdout: "", stderr: "" };
      }
      return { status: 1, stdout: "", stderr: "unexpected" };
    }),
  );

  assert.equal(store.get(KB_STAR_BIZ_ACCOUNT_KEY), undefined);
  store.put(KB_STAR_BIZ_ACCOUNT_KEY, ACCOUNT);
  assert.equal(store.get(KB_STAR_BIZ_ACCOUNT_KEY), ACCOUNT);
  store.delete(KB_STAR_BIZ_ACCOUNT_KEY);
  assert.equal(store.get(KB_STAR_BIZ_ACCOUNT_KEY), undefined);

  const put = calls.find(call => call.args[0] === "add-generic-password");
  assert.equal(put?.command, "security");
  assert.deepEqual(put?.args, [
    "add-generic-password",
    "-a",
    "ppomi",
    "-s",
    KB_STAR_BIZ_ACCOUNT_KEY,
    "-l",
    KB_STAR_BIZ_ACCOUNT_KEY,
    "-w",
    ACCOUNT,
    "-U",
  ]);
  const get = calls.find(call => call.args[0] === "find-generic-password");
  assert.ok(get && !get.args.includes(ACCOUNT));
});

test("Keychain errors do not echo the secret", () => {
  const store = new KeychainSecretStore(
    scripted(() => ({ status: 1, stdout: "", stderr: `denied ${ACCOUNT}` })),
  );
  assert.throws(() => store.put(KB_STAR_BIZ_ACCOUNT_KEY, ACCOUNT), (error: unknown) => {
    return (
      error instanceof SecretStoreError &&
      error.code === "failed" &&
      !error.message.includes(ACCOUNT)
    );
  });
});

test("CredentialManagerSecretStore puts the secret in child env, not argv", () => {
  const calls: { args: readonly string[]; env?: Readonly<Record<string, string>> }[] = [];
  let stored: string | undefined;
  const store = new CredentialManagerSecretStore(
    scripted((command, args, extraEnv) => {
      assert.equal(command, "powershell.exe");
      calls.push(extraEnv === undefined ? { args } : { args, env: extraEnv });
      const op = extraEnv?.PPOMI_SECRET_OP;
      if (op === "put") {
        stored = extraEnv?.PPOMI_SECRET_VALUE;
        return { status: 0, stdout: "", stderr: "" };
      }
      if (op === "get") {
        if (stored === undefined) return { status: 44, stdout: "", stderr: "" };
        return { status: 0, stdout: stored, stderr: "" };
      }
      stored = undefined;
      return { status: 0, stdout: "", stderr: "" };
    }),
  );

  store.put(KB_STAR_BIZ_ACCOUNT_KEY, ACCOUNT);
  assert.equal(store.get(KB_STAR_BIZ_ACCOUNT_KEY), ACCOUNT);
  store.delete(KB_STAR_BIZ_ACCOUNT_KEY);

  const put = calls[0];
  assert.ok(put?.args.includes("-EncodedCommand"));
  assert.equal(put?.args.join(" ").includes(ACCOUNT), false);
  assert.equal(put?.env?.PPOMI_SECRET_VALUE, ACCOUNT);
  assert.equal(put?.env?.PPOMI_SECRET_KEY, KB_STAR_BIZ_ACCOUNT_KEY);
});

test("Linux has no live OS store", () => {
  if (process.platform === "linux") {
    assert.throws(() => openOsSecretStore(), (error: unknown) => {
      return error instanceof SecretStoreError && error.code === "unavailable";
    });
  }
});
