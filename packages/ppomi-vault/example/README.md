# ppomi-vault example

Mac→Win round-trip on the in-memory ciphertext store: put, existing-device approve + fingerprint, get. Not a Mac/Win UI. QR is out.

```sh
node --experimental-strip-types packages/ppomi-vault/example/src/main.ts
```

Prints PASS, the hook key id, a last-4 mask, box length, and the public fingerprint phrase. Never prints fixture digits or the recovery passphrase.
