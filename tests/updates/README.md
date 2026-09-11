# Test-only signed update fixtures

These small, non-executable fixture packages use an ephemeral P-256 key generated only for cross-platform verifier tests. The private key was discarded. Never package this public key in a real app. Each valid fixture has sequence 42, channel preview and release fixture-test-only; tampered.json mutates signed payload bytes and must fail signature validation. The public-key.txt value is the same 65-byte uncompressed X9.63 point used by Swift, Android and Node tests.

To deliberately regenerate all fixture packages and their test public key together, run `node scripts/family-update-fixtures.mjs --write-test-fixtures`. Production packages use the separate `family-update.mjs pack` command and an explicit offline private key.
