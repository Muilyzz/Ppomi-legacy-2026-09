# ppomi-secrets example

Fixture always PASSes (`FakeSecretStore` from `ppomi-secrets/testing` + the MZZ-46 `AccountCapturePort.handoff` shape). Live Keychain / Credential Manager is opt-in and uses a **dummy** `ppomi/secrets-live-probe` value: put, get, refuse a second put without `{ overwrite: true }`, then delete. Never a real account number.

```sh
node --experimental-strip-types packages/ppomi-secrets/example/src/main.ts
PPOMI_SECRETS_LIVE=1 node --experimental-strip-types packages/ppomi-secrets/example/src/main.ts
```

Off-macOS/Windows, or without `PPOMI_SECRETS_LIVE=1`: live **SKIP** (exit 0). Fixture still PASSes.

On a Mac no Keychain access prompt is expected: the item is created and read by `/usr/bin/security`, which its ACL trusts (see the package README, *Protection level*). A locked login keychain prompts to unlock. The live probe has not yet been run on a real Mac or Windows machine (MZZ-47 DoD).
