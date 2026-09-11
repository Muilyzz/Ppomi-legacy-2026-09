# ppomi-secrets

Local OS secret store for values that must not land in `StepResult`, logs, catalog JSON, or git. Not a vault sync, not Clerk, not `ppomi-brain` `Memory` (run events).

```ts
import {
  FakeSecretStore,
  KB_STAR_BIZ_ACCOUNT_KEY,
  KeychainSecretStore,
  storeKbStarBizAccount,
} from "ppomi-secrets";

const store = new FakeSecretStore(); // tests
// const store = new KeychainSecretStore(); // Mac live
capture.handoff(account => store.put(KB_STAR_BIZ_ACCOUNT_KEY, account));
// or
storeKbStarBizAccount(store, capture);
```

`get` returns plaintext **only to the caller**. Runtime evidence is `{ masked: "****last4", key }` — never the raw number.

## Port

`put(key, value)` / `get(key)` / `delete(key)`. Keys are `ppomi/<id>` (`ppomi/kb-star-biz/account` for KB스타기업뱅킹). Missing `get` is `undefined`. Missing `delete` is a no-op.

| Backend | Status |
| --- | --- |
| `FakeSecretStore` | unit / CI |
| `KeychainSecretStore` | Mac live (`security` generic password, account `ppomi`) |
| `CredentialManagerSecretStore` | Windows live (CredWrite / CredRead) |
| Linux | no OS backend — use the fake |

## MZZ-46 handoff

PR #52 / [MZZ-46](https://linear.app/muilyzz/issue/MZZ-46) `AccountCapturePort` is one-shot: ingest masked rows, then `handoff(sink)` gives the raw digits once. After the iPhone path `read-account` step:

```ts
import { AccountCapturePort } from "ppomi-body-iphone-mirroring";
import { KB_STAR_BIZ_ACCOUNT_KEY, storeKbStarBizAccount } from "ppomi-secrets";

const capture = new AccountCapturePort();
capture.ingest(screenRows); // StepResult sees mask only
const evidence = storeKbStarBizAccount(store, capture);
// evidence = { masked: "****7890", key: "ppomi/kb-star-biz/account" }
```

The catalog JSON names the path only. It must not contain an account number. The store key lives in this package, not in `catalogs/paths/`.

Do not write the raw value to chat, Linear, git, or agent memory.

## Mac live how-to

Needs `/usr/bin/security`. First write may prompt Keychain access for Terminal / iTerm / Cursor.

```sh
npm --prefix packages/ppomi-secrets test
node --experimental-strip-types packages/ppomi-secrets/example/src/main.ts
# dummy probe value, then delete — not a bank account
PPOMI_SECRETS_LIVE=1 node --experimental-strip-types packages/ppomi-secrets/example/src/main.ts
```

Equivalent CLI (do **not** paste a real account here):

```sh
security add-generic-password -a ppomi -s ppomi/kb-star-biz/account -l ppomi/kb-star-biz/account -w '<value>' -U
security find-generic-password -a ppomi -s ppomi/kb-star-biz/account -w   # stdout = plaintext to this tty only
security delete-generic-password -a ppomi -s ppomi/kb-star-biz/account
```

Windows live: `PPOMI_SECRETS_LIVE=1` on win32 uses Credential Manager. Target name is the same key.

## Out of scope

Client E2E multi-device vault, Windows 공동인증서 (MZZ-48), ML on account data, Clerk.
