# ppomi-body-iphone-mirroring

iPhone Mirroring `OsUiDriver` for `ppomi-body` (`phone_*` on the Mac window `com.apple.ScreenContinuity`). Not on-device iOS AX and not `ppomi-body-macos` desktop AX.

`StepResult.driver` is `phone`.

Live tools: `LiveIphoneMirroringTools` (Mac AX of the mirroring window, then `phone` CLI OCR when AX shows only the window's own chrome — title, Home / App Switcher, connect / pause overlays). Tests use `FixtureIphoneMirroringTools`. Any 10–16 digit run with OCR separators (dashes, spaces) is masked (`****last4`) on screen rows and in StepResult, also when OCR splits it over two boxes of one line; the rest of the screen text stays in Runtime evidence. `AccountCapturePort` captures KB-shaped accounts only and hands the raw digits to the secret-store slice once per read.

Gates: an OCR tap re-captures and re-OCRs right before the click and taps only the box that still shows the same text at overlapping bounds inside the window (`stale_screen` otherwise, never read-time coordinates); reads older than 15 s are taken again; pay words, 출금 / 비밀번호 / OTP / 인증번호 / 동의 and English purchase words are `protected_action` (`확인` is not); `phone_key` allows `escape` / `down` / `pagedown` / `home` / `switcher` only (`return`, `paste` refused); exec errors reach `StepResult` as a code plus a masked line. The OCR screenshot goes through `phone capture-private` into a fresh private temp directory that is removed on every path.

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

Off-macOS, missing app, Accessibility denial, no mirroring window, or a window whose only readable text is Mac chrome (no `phone` binary / no 화면 기록) **skips (exit 0)**. When the phone UI itself was read (`source=ocr`, or AX with non-chrome labels), the live probe **PASS**es a `ui.read` Runtime step. It does not tap Home/Switcher and does not open KB스타기업뱅킹; it does activate the iPhone Mirroring window on the Mac.

KB path `kb-star-biz-iphone@0.1.0`: human login → 계좌조회 → human account detail → masked read. No payment. Grant is `ui.read` plus the navigate click.
