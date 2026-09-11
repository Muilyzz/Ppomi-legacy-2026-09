import assert from "node:assert/strict";
import { test } from "node:test";
import {
  CredentialManagerSecretStore,
  KB_STAR_BIZ_ACCOUNT_KEY,
  KeychainSecretStore,
  SecretStoreError,
  openOsSecretStore,
  secretEvidence,
  storeKbStarBizAccount,
  type AccountHandoff,
  type SecretExec,
  type SecretExecOptions,
  type SecretExecResult,
} from "../src/index.ts";
import { FakeSecretStore } from "../src/testing.ts";

const ACCOUNT = "001234567890";
const ACCOUNT_HEX = Buffer.from(ACCOUNT, "utf8").toString("hex");
const SECURITY = "/usr/bin/security";

function scripted(
  handler: (command: string, args: readonly string[], options?: SecretExecOptions) => SecretExecResult,
): SecretExec {
  return handler;
}

function isCode(code: SecretStoreError["code"]): (error: unknown) => boolean {
  return (error: unknown) => error instanceof SecretStoreError && error.code === code;
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

interface SecurityCall {
  readonly command: string;
  readonly args: readonly string[];
  readonly input: string | undefined;
}

/** Fake `security`: `-i` reads one command line from stdin; duplicates exit 45 unless `-U`. */
function fakeSecurity(calls: SecurityCall[]): { exec: SecretExec; stored: () => string | undefined } {
  let stored: string | undefined;
  const exec = scripted((command, args, options) => {
    calls.push({ command, args, input: options?.input });
    const words = args[0] === "-i" ? (options?.input ?? "").trimEnd().split(" ") : [...args];
    const sub = words[0];
    if (sub === "add-generic-password") {
      if (!(options?.input ?? "").endsWith("\n")) return { status: 1, stdout: "", stderr: "line dropped" };
      const hex = words[words.indexOf("-X") + 1] ?? "";
      if (stored !== undefined && !words.includes("-U")) {
        return { status: 45, stdout: "", stderr: "SecKeychainItemCreateFromContent: The specified item already exists in the keychain." };
      }
      stored = Buffer.from(hex, "hex").toString("utf8");
      return { status: 0, stdout: "", stderr: "" };
    }
    if (sub === "find-generic-password") {
      if (stored === undefined) return { status: 44, stdout: "", stderr: "could not be found" };
      return { status: 0, stdout: `${stored}\n`, stderr: "" };
    }
    if (sub === "delete-generic-password") {
      const had = stored !== undefined;
      stored = undefined;
      return { status: had ? 0 : 44, stdout: "", stderr: "" };
    }
    return { status: 1, stdout: "", stderr: "unexpected" };
  });
  return { exec, stored: () => stored };
}

test("fake store put/get/delete and rejects bad keys", () => {
  const store = new FakeSecretStore();
  store.put(KB_STAR_BIZ_ACCOUNT_KEY, ACCOUNT);
  assert.equal(store.get(KB_STAR_BIZ_ACCOUNT_KEY), ACCOUNT);
  store.delete(KB_STAR_BIZ_ACCOUNT_KEY);
  assert.equal(store.get(KB_STAR_BIZ_ACCOUNT_KEY), undefined);
  store.delete(KB_STAR_BIZ_ACCOUNT_KEY);

  assert.throws(() => store.put("kb-account", ACCOUNT), isCode("invalid_key"));
  assert.throws(() => store.put("ppomi/../etc", ACCOUNT), isCode("invalid_key"));
  assert.throws(() => store.put(KB_STAR_BIZ_ACCOUNT_KEY, ""), isCode("invalid_value"));
});

test("fake store refuses to overwrite unless { overwrite: true }", () => {
  const store = new FakeSecretStore();
  store.put(KB_STAR_BIZ_ACCOUNT_KEY, ACCOUNT);
  assert.throws(() => store.put(KB_STAR_BIZ_ACCOUNT_KEY, "000000000001"), isCode("exists"));
  assert.equal(store.get(KB_STAR_BIZ_ACCOUNT_KEY), ACCOUNT);
  store.put(KB_STAR_BIZ_ACCOUNT_KEY, "000000000001", { overwrite: true });
  assert.equal(store.get(KB_STAR_BIZ_ACCOUNT_KEY), "000000000001");
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

test("KB handoff onto a stored key throws exists, consumes the capture, and needs an explicit overwrite", () => {
  const store = new FakeSecretStore();
  assert.notEqual(storeKbStarBizAccount(store, new OnceCapture(ACCOUNT)), null);

  const second = new OnceCapture("000000000001");
  assert.throws(() => storeKbStarBizAccount(store, second), isCode("exists"));
  assert.equal(store.get(KB_STAR_BIZ_ACCOUNT_KEY), ACCOUNT);
  assert.equal(second.handoff(() => {}), false);

  const evidence = storeKbStarBizAccount(store, new OnceCapture("000000000001"), { overwrite: true });
  assert.deepEqual(evidence, { masked: "****0001", key: KB_STAR_BIZ_ACCOUNT_KEY });
  assert.equal(store.get(KB_STAR_BIZ_ACCOUNT_KEY), "000000000001");
});

test("secretEvidence never carries the raw value", () => {
  const evidence = secretEvidence("ppomi/secrets-live-probe", ACCOUNT);
  assert.equal(JSON.stringify(evidence).includes(ACCOUNT), false);
  assert.equal(evidence.masked, "****7890");
});

test("KeychainSecretStore never puts the secret in argv: security -i, command on stdin, value as -X hex", () => {
  const calls: SecurityCall[] = [];
  const fake = fakeSecurity(calls);
  const store = new KeychainSecretStore(fake.exec);

  assert.equal(store.get(KB_STAR_BIZ_ACCOUNT_KEY), undefined);
  store.put(KB_STAR_BIZ_ACCOUNT_KEY, ACCOUNT);
  assert.equal(fake.stored(), ACCOUNT);
  assert.equal(store.get(KB_STAR_BIZ_ACCOUNT_KEY), ACCOUNT);
  store.delete(KB_STAR_BIZ_ACCOUNT_KEY);
  assert.equal(store.get(KB_STAR_BIZ_ACCOUNT_KEY), undefined);

  for (const call of calls) {
    assert.equal(call.command, SECURITY);
    assert.equal(call.args.join(" ").includes(ACCOUNT), false);
    assert.equal(call.args.join(" ").includes(ACCOUNT_HEX), false);
  }

  const put = calls.find(call => call.args[0] === "-i");
  assert.ok(put);
  assert.deepEqual(put.args, ["-i"]);
  assert.equal(
    put.input,
    `add-generic-password -a ppomi -s ${KB_STAR_BIZ_ACCOUNT_KEY} -l ${KB_STAR_BIZ_ACCOUNT_KEY} -X ${ACCOUNT_HEX}\n`,
  );
  assert.equal(put.input.includes(ACCOUNT), false);
  assert.equal(put.input.includes("-U"), false);

  const get = calls.find(call => call.args[0] === "find-generic-password");
  assert.ok(get);
  assert.deepEqual(get.args, ["find-generic-password", "-a", "ppomi", "-s", KB_STAR_BIZ_ACCOUNT_KEY, "-w"]);
  assert.equal(get.input, undefined);
  const del = calls.find(call => call.args[0] === "delete-generic-password");
  assert.ok(del);
  assert.equal(del.input, undefined);
});

test("KeychainSecretStore maps a duplicate item (exit 45) to exists and only sends -U on overwrite", () => {
  const calls: SecurityCall[] = [];
  const fake = fakeSecurity(calls);
  const store = new KeychainSecretStore(fake.exec);

  store.put(KB_STAR_BIZ_ACCOUNT_KEY, ACCOUNT);
  assert.throws(() => store.put(KB_STAR_BIZ_ACCOUNT_KEY, "000000000001"), isCode("exists"));
  assert.equal(fake.stored(), ACCOUNT);

  store.put(KB_STAR_BIZ_ACCOUNT_KEY, "000000000001", { overwrite: true });
  assert.equal(fake.stored(), "000000000001");
  const overwrite = calls.at(-1);
  assert.ok(overwrite);
  assert.ok(overwrite.input?.endsWith(" -U\n"));
  assert.equal(overwrite.args.includes("-U"), false);
});

test("Keychain errors do not echo the secret or its hex", () => {
  const store = new KeychainSecretStore(
    scripted(() => ({ status: 1, stdout: "", stderr: `denied ${ACCOUNT} ${ACCOUNT_HEX} ${"x".repeat(200)}` })),
  );
  assert.throws(() => store.put(KB_STAR_BIZ_ACCOUNT_KEY, ACCOUNT), (error: unknown) => {
    return (
      error instanceof SecretStoreError &&
      error.code === "failed" &&
      !error.message.includes(ACCOUNT) &&
      !error.message.includes(ACCOUNT_HEX)
    );
  });
});

test("CredentialManagerSecretStore uses the absolute powershell path and puts the secret in child env, not argv", () => {
  const calls: { command: string; args: readonly string[]; env?: Readonly<Record<string, string>> }[] = [];
  let stored: string | undefined;
  const store = new CredentialManagerSecretStore(
    scripted((command, args, options) => {
      const env = options?.extraEnv;
      calls.push(env === undefined ? { command, args } : { command, args, env });
      const op = env?.PPOMI_SECRET_OP;
      if (op === "put") {
        if (stored !== undefined && env?.PPOMI_SECRET_OVERWRITE !== "1") return { status: 45, stdout: "", stderr: "" };
        stored = env?.PPOMI_SECRET_VALUE;
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
  assert.throws(() => store.put(KB_STAR_BIZ_ACCOUNT_KEY, "000000000001"), isCode("exists"));
  store.put(KB_STAR_BIZ_ACCOUNT_KEY, "000000000001", { overwrite: true });
  assert.equal(store.get(KB_STAR_BIZ_ACCOUNT_KEY), "000000000001");
  store.delete(KB_STAR_BIZ_ACCOUNT_KEY);

  for (const call of calls) {
    assert.ok(call.command.endsWith("\\System32\\WindowsPowerShell\\v1.0\\powershell.exe"), call.command);
    assert.notEqual(call.command, "powershell.exe");
    assert.ok(call.args.includes("-EncodedCommand"));
    assert.equal(call.args.join(" ").includes(ACCOUNT), false);
  }
  const put = calls[0];
  assert.equal(put?.env?.PPOMI_SECRET_VALUE, ACCOUNT);
  assert.equal(put?.env?.PPOMI_SECRET_KEY, KB_STAR_BIZ_ACCOUNT_KEY);
  assert.equal(put?.env?.PPOMI_SECRET_OVERWRITE, "0");
  const overwrite = calls[3];
  assert.equal(overwrite?.env?.PPOMI_SECRET_OVERWRITE, "1");
});

test("Linux has no live OS store", () => {
  if (process.platform === "linux") {
    assert.throws(() => openOsSecretStore(), isCode("unavailable"));
  }
});
