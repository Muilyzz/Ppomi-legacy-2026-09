# ppomi-secrets

Local OS secret store for values that must not land in `StepResult`, logs, catalog JSON, or git. Not a vault sync, not Clerk, not `ppomi-brain` `Memory` (run events).

```ts
import { KB_STAR_BIZ_ACCOUNT_KEY, KeychainSecretStore, storeKbStarBizAccount } from "ppomi-secrets";
import { FakeSecretStore } from "ppomi-secrets/testing"; // tests and examples only

const store = new KeychainSecretStore(); // Mac live; `openOsSecretStore()` picks the platform backend
capture.handoff(account => store.put(KB_STAR_BIZ_ACCOUNT_KEY, account));
// or
storeKbStarBizAccount(store, capture);
```

`get` returns plaintext to the caller. Runtime evidence is `{ masked: "****last4", key }` — never the raw number. What "to the caller" does **not** mean is in *Protection level* below.

## Port

`put(key, value, { overwrite? })` / `get(key)` / `delete(key)`. Keys are `ppomi/<id>` (`ppomi/kb-star-biz/account` for KB스타기업뱅킹). Missing `get` is `undefined`. Missing `delete` is a no-op. `put` onto a key that already holds a value throws `SecretStoreError` `exists` unless `{ overwrite: true }` is passed — nothing is replaced silently, on any backend.

| Backend | Status |
| --- | --- |
| `KeychainSecretStore` | Mac live (`/usr/bin/security` generic password, account `ppomi`) — **not yet run on a Mac** |
| `CredentialManagerSecretStore` | Windows live (CredWrite / CredRead via `powershell.exe`) — **not yet run on Windows** |
| Linux | no OS backend |

`FakeSecretStore` (`ppomi-secrets/testing`) is an in-memory test double, not a backend: nothing persists past the process. Do not wire it into a runtime.

## Protection level — read this before trusting it

Both backends protect the value **at rest and against other OS users**. Neither protects it from **other processes running as the same user**:

- **Mac.** The item is written by `/usr/bin/security`, so its ACL trusts `/usr/bin/security` — which every Mac has. Any process running as you can run `security find-generic-password -a ppomi -s ppomi/kb-star-biz/account -w` and get the plaintext **with no prompt** while the login keychain is unlocked (all session, by default). There is no per-app or per-terminal Keychain prompt for this item; the only dialog you may ever see is the keychain *unlock* dialog. Encrypted at rest under your login password; not iCloud-synced.
- **Windows.** Generic credentials are per-user DPAPI; any process in your session can `CredRead` them with no prompt. `CRED_PERSIST_LOCAL_MACHINE` — survives reboot, not roamed.

What the store does give you: the number is not in git, catalog JSON, `StepResult`, logs, or shell history; a `put` never puts the plaintext in a process command line (Mac: `security -i` reads the command from stdin with the value as `-X <hex>`; Windows: value in the child environment); errors scrub the value; and a second `put` refuses to overwrite unless asked.

## MZZ-46 handoff

PR #52 / [MZZ-46](https://linear.app/muilyzz/issue/MZZ-46) `AccountCapturePort` is one-shot: ingest masked rows, then `handoff(sink)` gives the raw digits once. After the iPhone path `read-account` step:

```ts
import { AccountCapturePort } from "ppomi-body-iphone-mirroring";
import { KB_STAR_BIZ_ACCOUNT_KEY, storeKbStarBizAccount } from "ppomi-secrets";

const capture = new AccountCapturePort();
capture.ingest(screenRows); // StepResult sees mask only
const evidence = storeKbStarBizAccount(store, capture);
// evidence = { masked: "****7890", key: "ppomi/kb-star-biz/account" }
// a later capture onto the same key throws `exists`; pass { overwrite: true } deliberately
```

If `put` throws (`exists`, Keychain failure), the capture is already consumed: re-run the read step. The catalog JSON names the path only. It must not contain an account number. The store key lives in this package, not in `catalogs/paths/`.

Do not write the raw value to chat, Linear, git, or agent memory.

## Live status (MZZ-47 DoD)

[MZZ-47](https://linear.app/muilyzz/issue/MZZ-47) requires a live run on at least one real Mac or Windows machine. **That has not happened yet** — every check so far ran on Linux with the fake store or an injected `security` / `powershell.exe` stand-in. The Mac worker runs the probe below and records the result on the ticket.

## Mac live how-to

Needs `/usr/bin/security`. No Keychain access prompt is expected (see *Protection level*); a locked login keychain prompts to unlock.

```sh
npm --prefix packages/ppomi-secrets test
node --experimental-strip-types packages/ppomi-secrets/example/src/main.ts
# dummy probe value under ppomi/secrets-live-probe: put, get, refuse-overwrite, delete — never a bank account
PPOMI_SECRETS_LIVE=1 node --experimental-strip-types packages/ppomi-secrets/example/src/main.ts
```

Manual CLI, if you ever need it. Put `-w` **last with no value** so `security` prompts for it hidden; never type the value inline (`-w '<value>'`) — it lands in shell history and `ps`:

```sh
security add-generic-password -a ppomi -s ppomi/kb-star-biz/account -l ppomi/kb-star-biz/account -w
security delete-generic-password -a ppomi -s ppomi/kb-star-biz/account
```

Add `-U` only to replace an existing item. Reading back with `find-generic-password … -w` prints the plaintext into your terminal scrollback; verify on the dummy probe key, not the real one.

Windows live: `PPOMI_SECRETS_LIVE=1` on win32 uses Credential Manager via `%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe`. Target name is the same key.

## Out of scope

Client E2E multi-device vault, Windows 공동인증서 (MZZ-48), ML on account data, Clerk.
