#!/bin/sh
# dist/Ppomi.app from the SwiftPM release build: scripts/make-app.sh (from anywhere).
# Ad-hoc output is for packaging checks only: its cdhash identity changes with every build and breaks TCC continuity.
# For the installed local app use LOCAL_SIGN_ID="Apple Development: …" so the designated requirement stays stable.
# Developer ID + 공증:  SIGN_ID="Developer ID Application: … (TEAMID)" NOTARY_PROFILE=<keychain profile> VERSION=0.1.0 scripts/make-app.sh
#   → hardened runtime + Ppomi.entitlements (audio-input), timestamp, notarytool submit --wait, staple, dist/Ppomi-<VERSION>.zip for download.
set -eu
if [ -n "${LOCAL_SIGN_ID:-}" ] && { [ -n "${SIGN_ID:-}" ] || [ -n "${NOTARY_PROFILE:-}" ]; }; then
    echo "Use LOCAL_SIGN_ID for local development OR SIGN_ID/NOTARY_PROFILE for distribution, not both." >&2
    exit 1
fi
VERSION=${VERSION:-0.1.0}
ROOT=$(cd "$(dirname "$0")/.." && pwd)
APP=$ROOT/dist/Ppomi.app
cd "$ROOT/Ppomi"
swift build -c release
BIN=$(swift build -c release --show-bin-path)

rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/Ppomi" "$APP/Contents/MacOS/"
# Resources: Views/Web.swift reads Ppomi_Ppomi.bundle from Contents/Resources first (SwiftPM's own Bundle.module accessor only
# looks at the .app root, which codesign rejects, and at $BIN), so the app stands alone once this copy is in place.
cp -R "$BIN/Ppomi_Ppomi.bundle" "$APP/Contents/Resources/"
# The release endpoint and verification key are part of the native signature, never downloaded configuration.
if [ -n "${PPOMI_UPDATES_CONFIG:-}" ]; then
    node "$ROOT/scripts/family-update.mjs" validate-config --config "$PPOMI_UPDATES_CONFIG"
    cp "$PPOMI_UPDATES_CONFIG" "$APP/Contents/Resources/Updates.json"
fi
swiftc -O "$ROOT/phone.swift" -o "$APP/Contents/MacOS/phone"    # Collect/Phone.swift looks next to the executable first

# Info.plist: the embedded one (usage strings) plus the bundle keys.
P=$APP/Contents/Info.plist
cp "$ROOT/Ppomi/Sources/Ppomi/Info.plist" "$P"
for kv in "CFBundleIdentifier string com.muilyzz.ppomi" "CFBundleDisplayName string 뽀미" "CFBundleExecutable string Ppomi" \
          "CFBundlePackageType string APPL" "CFBundleVersion string $VERSION" "CFBundleShortVersionString string $VERSION" \
          "LSMinimumSystemVersion string 26.0" "CFBundleIconFile string Ppomi.icns" "NSHighResolutionCapable bool true"; do
    set -- $kv; /usr/libexec/PlistBuddy -c "Add :$1 $2 $3" "$P"
done

# Icon: brand/icon.png → iconset → icns (sizes above the source are upscaled; drop a 1024px icon.png in brand/ to fix that).
SET=$ROOT/dist/Ppomi.iconset; rm -rf "$SET"; mkdir -p "$SET"
for s in 16 32 128 256 512; do
    sips -z $s $s "$ROOT/brand/icon.png" --out "$SET/icon_${s}x${s}.png" >/dev/null
    sips -z $((s * 2)) $((s * 2)) "$ROOT/brand/icon.png" --out "$SET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$SET" -o "$APP/Contents/Resources/Ppomi.icns"; rm -rf "$SET"

if [ -n "${LOCAL_SIGN_ID:-}" ]; then
    # The helper posts keyboard events: TCC judges that by code-signing identifier, so it must share the app's own
    # identifier (and its 손쉬운 사용 grant). A distinct helper identifier keeps clicks but silently drops every key.
    codesign --force --sign "$LOCAL_SIGN_ID" --timestamp=none --identifier com.muilyzz.ppomi "$APP/Contents/MacOS/phone"
    codesign --force --sign "$LOCAL_SIGN_ID" --timestamp=none "$APP"
    codesign --verify --deep --strict "$APP"
    echo "$APP (local development signature; not notarized)"; exit 0
fi

if [ -z "${SIGN_ID:-}" ]; then
    codesign --force --sign - "$APP/Contents/MacOS/phone"
    codesign --force --deep --sign - "$APP"
    echo "$APP"; exit 0
fi

# Developer ID: inner helper first, then the bundle (no --deep: it would re-sign the helper without the entitlements).
ENT=$ROOT/Ppomi/Sources/Ppomi/Ppomi.entitlements
codesign --force --options runtime --timestamp --sign "$SIGN_ID" "$APP/Contents/MacOS/phone"
codesign --force --options runtime --timestamp --entitlements "$ENT" --sign "$SIGN_ID" "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"
ZIP=$ROOT/dist/Ppomi-$VERSION.zip
if [ -n "${NOTARY_PROFILE:-}" ]; then
    ditto -c -k --keepParent "$APP" "$ZIP"
    xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$APP"
    spctl -a -vv -t exec "$APP"
fi
rm -f "$ZIP"; ditto -c -k --keepParent "$APP" "$ZIP"       # the download: stapled app inside
echo "$ZIP"
