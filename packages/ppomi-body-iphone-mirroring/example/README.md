# ppomi-body-iphone-mirroring example

One-step `ppomi-body` smoke via Mac `phone_*`. Default: fixture `Runtime` click.

Live iPhone Mirroring: `PPOMI_BODY_LIVE=1` on a Mac with the mirroring window **open and connected**. The probe reads through `LiveIphoneMirroringTools` (AX, OCR only if AX labels are chrome-only). Off-macOS, Automation denial, or no window skips (exit 0).

## Prerequisites (human)

- Unlock the **Mac**. Open iPhone Mirroring and finish Connect if prompted.
- Leave the **iPhone locked** beside the Mac (same Apple ID, Wi-Fi + Bluetooth). Picking it up or unlocking it disconnects mirroring.
- Window shows the phone UI or Home / App Switcher — not “iPhone 사용 중” / disconnected.
- 손쉬운 사용 (+ 화면 기록 for OCR) granted to the terminal that runs Node.
- For OCR fallback: repo-root `phone` binary (`swiftc -O phone.swift -o phone`).

```sh
node --experimental-strip-types packages/ppomi-body-iphone-mirroring/example/src/main.ts
PPOMI_BODY_LIVE=1 node --experimental-strip-types packages/ppomi-body-iphone-mirroring/example/src/main.ts
```

The live probe is a `ui.read` only. The KB스타기업뱅킹 path (`catalogs/paths/kb-star-biz-iphone/0.1.0.json`) Homes only on cold start (`phone_key home`), then human login, and never logs a full account number.
