# ppomi-body-iphone-mirroring

iPhone Mirroring `OsUiDriver` for `ppomi-body` (`phone_*` on the Mac window `com.apple.ScreenContinuity`). Not on-device iOS AX and not `ppomi-body-macos` desktop AX.

`StepResult.driver` is `phone`.

Live tools: `LiveIphoneMirroringTools` (Mac AX of the mirroring window, then `phone` CLI OCR if AX is chrome-only). Tests use `FixtureIphoneMirroringTools`. Account numbers are masked (`****last4`) on screen rows and in StepResult; `AccountCapturePort` hands the raw digits once to the secret-store slice.

```sh
npm --prefix packages/ppomi-body-iphone-mirroring test
node --experimental-strip-types packages/ppomi-body-iphone-mirroring/example/src/main.ts
```

## Live on a Mac (mirroring connected)

The iPhone stays **locked** beside the Mac. Unlocking or picking it up breaks mirroring.

1. Unlock the Mac. Open **iPhone Mirroring** (`/System/Applications/iPhone Mirroring.app`) and complete Connect if asked.
2. Leave the phone locked, Wi-Fi + Bluetooth on, same Apple ID. Wait until Home / App Switcher chrome is visible (not “iPhone 사용 중”).
3. Grant **손쉬운 사용** (and **화면 기록** if OCR is needed) to Terminal / iTerm / Cursor.
4. Optional: `swiftc -O phone.swift -o phone` at the repo root so chrome-only AX can fall through to OCR.

```sh
PPOMI_BODY_LIVE=1 node --experimental-strip-types packages/ppomi-body-iphone-mirroring/example/src/main.ts
```

Off-macOS, missing app, Accessibility denial, or no mirroring window **skips (exit 0)**. When the window is open and readable, the live probe **PASS**es a `ui.read` Runtime step. It does not tap Home/Switcher and does not open KB스타기업뱅킹.

KB path `kb-star-biz-iphone@0.1.0`: **cold start** (first tool-call / explicit restart) sends `phone_key home` (`phone key home` = ⌘1 → SpringBoard) so AX is a known baseline, then opens KB스타기업뱅킹 and continues. **Pause/resume** (continue-after-failure) passes `Runtime.run(playbook, { fromStep })` and does **not** Home — the phone is still on the failed screen. Login / Face ID / account-detail stay human. No payment. Grant is `ui.read` plus `ui.control` for Home, open, and the navigate click.
