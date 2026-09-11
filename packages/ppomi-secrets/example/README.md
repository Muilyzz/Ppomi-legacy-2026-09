# ppomi-secrets example

Fixture always PASSes (`FakeSecretStore` + the MZZ-46 `AccountCapturePort.handoff` shape). Live Keychain / Credential Manager is opt-in and uses a **dummy** `ppomi/secrets-live-probe` value, then deletes it. Never a real account number.

```sh
node --experimental-strip-types packages/ppomi-secrets/example/src/main.ts
PPOMI_SECRETS_LIVE=1 node --experimental-strip-types packages/ppomi-secrets/example/src/main.ts
```

Off-macOS/Windows, or without `PPOMI_SECRETS_LIVE=1`: live **SKIP** (exit 0). Fixture still PASSes.

On a Mac, the first `security add-generic-password` may prompt Keychain access for the terminal that launched `node`. Allow it. See the package README for put/get/delete with `security`.
