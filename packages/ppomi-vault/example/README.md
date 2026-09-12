# ppomi-vault example

Mac→Win ciphertext round-trip through a mock store. Two fingerprint phrases travel by voice/eyes and never through the store: Win's phrase (Win screen → typed on the Mac) gates the approval, the Mac's phrase (Mac screen → typed on Win) gates accepting the wrap. Synthetic fixtures only; prints masks and the two public phrases.

```sh
node --experimental-strip-types packages/ppomi-vault/example/src/main.ts
```

The example wraps the recovery DEK at the Argon2id INTERACTIVE floor to stay fast; production omits the argument and gets MODERATE. No Clerk, no live store, no OS keychain.
