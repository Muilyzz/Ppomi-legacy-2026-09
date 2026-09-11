# ppomi-path example

Mini CLI: **load and validate** a versioned path catalog. Not the hub, not the Mac app.

Future library name: `ppomi-path` (MZZ-40). Today the product catalog still lives in `Ppomi/Sources/Ppomi/Catalog` and sibling `playbook-*` packs. This example is self-contained.

## Machine / env

| | |
| --- | --- |
| OS | Any (Linux / macOS / Windows) |
| Node | ≥ 22 |
| Secrets | None |
| Network | None |

## Commands

From the **repo root**:

```sh
pnpm --filter ppomi-path-example start
pnpm --filter ppomi-path example
node --experimental-strip-types packages/ppomi-path/example/src/main.ts
```

From this directory:

```sh
npm start
npm test
node --experimental-strip-types src/main.ts
node --experimental-strip-types src/main.ts --legacy
node --experimental-strip-types src/main.ts --fixture fixtures/catalog.json
node --experimental-strip-types src/main.ts --catalog ../../../Ppomi/Sources/Ppomi/Catalog
```

`--legacy` / `--catalog` uses `hub/lib/catalog.js` to validate the existing Swift Catalog packages. Skip that flag on a checkout that has no `Ppomi/Sources/Ppomi/Catalog`.

## What it checks

1. Bundled `fixtures/catalog.json` (schema, unique IDs, payment/submit targets).
2. Optional live Catalog directory (same rules as the hub).

Unit tests for a future `ppomi-path` library stay in `packages/ppomi-path/tests/` (mocks). Do not import this example from those tests.
