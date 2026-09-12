#!/bin/sh
# Install the Tauri consumer app to ONE path: /Applications/뽀미.app
# Same LOCAL_SIGN_ID idea as scripts/make-app.sh. Ad-hoc is not for permission smoke.
# Never writes *-prev.app or dist/backup — those are what Launch Services/TCC labeled 「previous」.
set -eu

ROOT=$(cd "$(dirname "$0")/.." && pwd)
ROOT=${PPOMI_ROOT:-$ROOT}
APP=${PPOMI_APP:-/Applications/뽀미.app}
BUNDLE_ID=com.muilyzz.ppomi
APPS_DIR=$(dirname "$APP")

usage() {
    echo "Usage: LOCAL_SIGN_ID=\"Apple Development: …\" $0" >&2
    echo "       $0 --hygiene     # sibling-path check only" >&2
    echo "       $0 --check       # hygiene + LOCAL_SIGN_ID (no build)" >&2
    exit 2
}

refuse() {
    echo "$1" >&2
    exit 1
}

# 「previous」 = leftover backup path/name + mixed binaries. Do not keep them runnable.
hygiene() {
    [ -e "$APPS_DIR/뽀미-prev.app" ] && refuse "Remove $APPS_DIR/뽀미-prev.app — LS/TCC treats *-prev.app as 「previous」."
    [ -e "$APPS_DIR/Ppomi-prev.app" ] && refuse "Remove $APPS_DIR/Ppomi-prev.app — LS/TCC treats *-prev.app as 「previous」."
    if [ -d "$ROOT/dist/backup" ]; then
        refuse "Remove $ROOT/dist/backup — runnable copies there show up as 「previous」 in TCC."
    fi
    if [ "$APP" = "/Applications/뽀미.app" ] && [ -e "/Applications/Ppomi.app" ]; then
        refuse "Remove /Applications/Ppomi.app — one consumer path only (/Applications/뽀미.app)."
    fi
}

require_sign_id() {
    if [ -z "${LOCAL_SIGN_ID:-}" ]; then
        refuse "Set LOCAL_SIGN_ID=\"Apple Development: …\" (same identity every local Mac build). Ad-hoc is not for permission smoke."
    fi
    if [ -n "${SIGN_ID:-}" ] || [ -n "${NOTARY_PROFILE:-}" ]; then
        refuse "Use LOCAL_SIGN_ID for local shell install OR SIGN_ID/NOTARY_PROFILE for distribution, not both."
    fi
}

quit_old() {
    [ "$(uname -s)" = "Darwin" ] || return 0
    osascript -e 'tell application "뽀미" to quit' 2>/dev/null || true
    osascript -e 'tell application "Ppomi" to quit' 2>/dev/null || true
    sleep 1
}

built_app() {
    for candidate in \
        "$ROOT/shell/src-tauri/target/release/bundle/macos/뽀미.app" \
        "$ROOT/shell/src-tauri/target/release/bundle/macos/Ppomi.app"
    do
        if [ -d "$candidate" ]; then
            echo "$candidate"
            return 0
        fi
    done
    refuse "tauri build produced no .app under shell/src-tauri/target/release/bundle/macos/"
}

install() {
    [ "$(uname -s)" = "Darwin" ] || refuse "install-shell.sh install is macOS only (use --hygiene / --check on other OS)."
    hygiene
    require_sign_id
    quit_old
    npm --prefix "$ROOT/shell" run build
    SRC=$(built_app)
    rm -rf "$APP"
    mkdir -p "$APPS_DIR"
    ditto "$SRC" "$APP"
    codesign --force --deep --sign "$LOCAL_SIGN_ID" --timestamp=none --identifier "$BUNDLE_ID" "$APP"
    codesign --verify --deep --strict "$APP"
    echo "$APP ($BUNDLE_ID, local development signature; not notarized)"
}

case "${1:-}" in
    -h|--help) usage ;;
    --hygiene) hygiene; echo "hygiene ok" ;;
    --check) hygiene; require_sign_id; echo "check ok" ;;
    "") install ;;
    *) usage ;;
esac
