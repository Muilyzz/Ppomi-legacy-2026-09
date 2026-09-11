# ppomi-vault example

Thin Mac→Win round-trip on the in-memory ciphertext store. Not a Mac/Win UI.

```sh
node --experimental-strip-types packages/ppomi-vault/example/src/main.ts
```

Prints PASS, the hook key id, a last-4 mask, and box length. Never prints the fixture digits.
