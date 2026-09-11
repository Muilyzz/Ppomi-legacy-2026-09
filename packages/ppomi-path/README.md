# ppomi-path

Schema, load, and validate for Ppomi **paths** (미리 가본 길). Path-side TypeScript is this package only.

Domain `playbook-*` packs are not added. Recipes live as a versioned JSON catalog under [`catalogs/paths/`](../../catalogs/paths/). JSON Schema: [`schema/ppomi-path.schema.json`](schema/ppomi-path.schema.json).

This package does not run steps. Execution stays in `ppomi-body` / `ppomi-body-*`.

The schema accepts the body core fields `effect` (`navigate` | `input` | `commit`), document `allowedOrigins`, and `require.wait` (positive integer milliseconds).

## Sample catalog

`kr-cert@0.1.0` is the absorbed `playbook-kr-cert` fixture (PR #8): 사업자 공동인증서 발급 준비. `payment` / `submit` keep targets so a later body run can fail-close. No secrets, resident-registration numbers, or device-approval fields.

`kb-star-biz-win-cert@0.1.0` is the KB스타기업뱅킹 Windows Edge 공동인증서 (구 공인) issuance path (MZZ-48): Playwright/`PageSurface` `goto` to the official cert-center and issue URLs, then `human` handoffs for terms, identity, OTP, passwords, UAC, and final confirm. No `payment` / `submit`. Post-issue store check is `%USERPROFILE%\AppData\LocalLow\NPKI` (see [`catalogs/paths/kb-star-biz-win-cert/README.md`](../../catalogs/paths/kb-star-biz-win-cert/README.md)).

```ts
import { loadPath, loadPathCatalog } from "ppomi-path";

const catalog = loadPathCatalog();
const krCert = loadPath("kr-cert", { version: "0.1.0" });
```

## Tests

```sh
npm --prefix packages/ppomi-path test
```
