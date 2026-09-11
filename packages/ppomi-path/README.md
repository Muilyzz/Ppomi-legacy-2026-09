# ppomi-path

Schema, load, and validate for Ppomi **paths** (미리 가본 길). Path-side TypeScript is this package only.

Domain `playbook-*` packs are not added. Recipes live as a versioned JSON catalog under [`catalogs/paths/`](../../catalogs/paths/). JSON Schema: [`schema/ppomi-path.schema.json`](schema/ppomi-path.schema.json).

This package does not run steps. Execution stays in `ppomi-body` / `ppomi-body-*`.

The schema accepts the body core fields `effect` (`navigate` | `input` | `commit`), document `allowedOrigins`, `require.wait` (positive integer milliseconds), and `key` (gesture name in `target`, e.g. iPhone `home`).

## Sample catalog

`kr-cert@0.1.0` is the absorbed `playbook-kr-cert` fixture (PR #8): 사업자 공동인증서 발급 준비. `payment` / `submit` keep targets so a later body run can fail-close. No secrets, resident-registration numbers, or device-approval fields.

`kb-star-biz-iphone@0.1.0` is the first iPhone Mirroring path (MZZ-46): cold start sends `phone_key home` (⌘1 → SpringBoard) then opens KB스타기업뱅킹; login and account-detail stay human; then 계좌조회 → `ui.read` of the 계좌번호 label. Continue-after-failure uses `Runtime.run(playbook, { fromStep })` and skips Home. No `payment` / `submit`. The body masks the account number in StepResult (`****last4`).

```ts
import { loadPath, loadPathCatalog } from "ppomi-path";

const catalog = loadPathCatalog();
const krCert = loadPath("kr-cert", { version: "0.1.0" });
```

## Tests

```sh
npm --prefix packages/ppomi-path test
```
