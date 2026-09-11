# kb-star-biz-win-cert@0.1.0

Windows Edge path for **KB스타기업뱅킹 공동인증서** (구 공인인증서) issuance navigation.

Not 금융인증서. Not KB국민인증서(기업). Automated steps only open the official pages. Terms, identity, account password, OTP, fee, storage media, cert password, VeraPort/Delfino/ASTx + UAC, and final confirm are `human` handoffs (MZZ-38). No `payment` / `submit` steps.

Grant: `ui.read` + `ui.control` only. Body must not auto-submit.

## Official URLs (public)

| Step | URL |
| --- | --- |
| Biz PC entry | https://obank.kbstar.com/quics?page=obiz |
| 인증센터(기업) | https://obranch.kbstar.com/quics?page=C100996 |
| 발급/재발급 | https://obiz.kbstar.com/quics?page=C019623 |
| 보안 프로그램 설치 | https://obank.kbstar.com/quics?page=C023664 |

Menu (before login, if the direct URL is blocked): **인증센터(기업) → 공동인증서 → 발급/재발급**. This catalog uses the official page IDs instead of guessing button labels.

`allowedOrigins`: `obank.kbstar.com`, `obiz.kbstar.com`, `obranch.kbstar.com`.

## Surfaces

| Surface | What |
| --- | --- |
| `PageSurface` / Playwright (`ppomi-body-playwright` when present; fixture: `DummyPageAdapter`) | `goto` cert center and issue URL |
| `ppomi-body-windows` UIA | native exe / Delfino / UAC dialogs — **observe only, then human** |
| Person | every `human` step |

## Dry / fixture (any OS)

```sh
npm --prefix packages/ppomi-path test
npm --prefix packages/ppomi-body-windows test
node --experimental-strip-types packages/ppomi-body-windows/example/src/kb-star-biz-win-cert.ts
```

Dry-run drives the two `goto` steps through `Runtime` + `PageSurface` + `DummyPageAdapter`, then prints human handoffs. It never types secrets.

## Live on a Windows VM (PR #48 executor pattern)

Issuance is not completed in CI. Live only opens Edge on the issue URL, then hands off.

```bat
node scripts\build-windows-executor.mjs --download
:: ARM64 Parallels:
node scripts\build-windows-executor.mjs --download --rid win-arm64

set PPOMI_EXECUTOR=%CD%\shell\src-tauri\resources\executor\ppomi-executor.exe
set PPOMI_BODY_LIVE=1
node --experimental-strip-types packages/ppomi-body-windows/example/src/kb-star-biz-win-cert.ts
```

Off-Windows live skips (exit 0). Without `PPOMI_BODY_LIVE=1` the script dry-runs. The executor is for optional UIA observation of OS dialogs; this path does not tap UAC or type into Delfino.

## After issue: NPKI probe (no secrets)

Conventional store (not certmgr unless a later path proves otherwise):

`%USERPROFILE%\AppData\LocalLow\NPKI`

The probe reports **file count** and **newest mtime** only. It does not print filenames, folder DNs, passwords, OTP, or account numbers.

```sh
node --experimental-strip-types packages/ppomi-body-windows/example/src/kb-star-biz-win-cert.ts --probe-npki
```

If the folder is missing: verify manually in Explorer after the person finishes issuance. A missing folder is not a failed issuance by itself.

## Out of scope

- Completing issuance without the person
- iPhone path (MZZ-46) / Keychain (MZZ-47)
- E2E vault / MyData
- Rewriting `ppomi-executor`
