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
| `PageSurface` / Playwright (`ppomi-body-playwright` is not on `main` yet; fixture: `DummyPageAdapter`) | `goto` cert center and issue URL |
| `ppomi-body-windows` UIA | native exe / Delfino / UAC dialogs — **observe only, then human**. Not used by this path's example today. |
| Person | every `human` step |

The page IDs `C100996` / `C019623` are KB menu codes recorded when this path was written (PR #56, 2026-09-11); no test verifies them against the live site. They are **fragile**: if either URL 404s or bounces to a different page, re-verify through the menu path above before editing the catalog, and bump the path version.

## Dry / fixture (any OS)

```sh
npm --prefix packages/ppomi-path test
npm --prefix packages/ppomi-body-windows test
node --experimental-strip-types packages/ppomi-body-windows/example/src/kb-star-biz-win-cert.ts
```

Dry-run drives the two `goto` steps through `Runtime` + `PageSurface` + `DummyPageAdapter`, then prints human handoffs. It never types secrets.

## Live on a Windows VM

Issuance is not completed in CI. Live opens **one new Edge window on the issue URL in the person's own profile, then stops**. Nothing is clicked, typed, or closed; the person continues from there. No `ppomi-executor` is needed or used by this example.

```bat
set PPOMI_BODY_LIVE=1
node --experimental-strip-types packages/ppomi-body-windows/example/src/kb-star-biz-win-cert.ts
```

Off-Windows live skips (exit 0). Without `PPOMI_BODY_LIVE=1` the script dry-runs. `PPOMI_EDGE` overrides the `msedge.exe` location.

Open-and-close smoke (VMs only): `set PPOMI_KB_CERT_CLOSE_EDGE=1` opens the URL in a fresh `--user-data-dir` under `%TEMP%` and closes **that instance only**, after `tasklist /FI "PID eq <pid>"` confirms the PID is still alive and is `msedge.exe`. The person's Edge profile is never touched, there is no timer, and when the check fails the isolated window is simply left open.

## After issue: NPKI probe (no secrets)

Conventional store (not certmgr unless a later path proves otherwise):

`%USERPROFILE%\AppData\LocalLow\NPKI`

The probe reports **file count**, **newest mtime** and `root=default|override` only. It does not print paths, filenames, folder DNs, passwords, OTP, or account numbers. It never follows links, descends at most 3 levels (`<CA>\USER\<DN folder>`) and stops after 2048 entries (`truncated`).

```sh
node --experimental-strip-types packages/ppomi-body-windows/example/src/kb-star-biz-win-cert.ts --probe-npki
```

`PPOMI_NPKI_ROOT` may point at another store, but only an absolute directory strictly under `%USERPROFILE%` (not the profile itself, not a link); anything else is reported as `refused`.

If the folder is missing: verify manually in Explorer after the person finishes issuance. A missing folder is not a failed issuance by itself.

## Out of scope

- Completing issuance without the person
- iPhone path (MZZ-46) / Keychain (MZZ-47)
- E2E vault / MyData
- Rewriting `ppomi-executor`
