#!/bin/sh
# Open the existing 뽀미.app Mac shell. No new package. No store / notarized signing.
# Finder: double-click scripts/open-mac-shell.command
# CLI:    scripts/open-mac-shell.sh [--build] [--dry-run] [--self-check]
set -eu

ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
APP_DIST="$ROOT/dist/Ppomi.app"
APP_INSTALLED_KO="/Applications/뽀미.app"
APP_INSTALLED_EN="/Applications/Ppomi.app"

usage() {
    cat <<'EOF'
Usage: scripts/open-mac-shell.sh [--build] [--dry-run] [--self-check]

  (default)  Open /Applications/뽀미.app, else dist/Ppomi.app, else build then open.
  --build    Always run scripts/make-app.sh (ad-hoc or LOCAL_SIGN_ID), then open dist/Ppomi.app.
  --dry-run  Print the same operator lines and the chosen app path. Do not build or open.
  --self-check
             Linux-safe asserts (dry-run text + SIGN_ID refuse).

Store signing is refused: unset SIGN_ID and NOTARY_PROFILE.
Local TCC-stable sign: LOCAL_SIGN_ID="Apple Development: …"
EOF
}

refuse_store_signing() {
    if [ -n "${SIGN_ID:-}" ] || [ -n "${NOTARY_PROFILE:-}" ]; then
        echo "이 스크립트는 스토어/공증 서명을 하지 않습니다. SIGN_ID·NOTARY_PROFILE을 빼고 실행하세요. 로컬은 LOCAL_SIGN_ID만." >&2
        exit 1
    fi
}

print_operator() {
    cat <<EOF
v0.2 Mac 셸 = 이미 있는 뽀미.app. 새 패키지 없음.
빌드: LOCAL_SIGN_ID=… $ROOT/scripts/make-app.sh  →  dist/Ppomi.app (공증·스토어 서명 없음)

web / Clerk (ppomi-web):
  cd "$ROOT/web" && test -f .env.local || cp .env.example .env.local
  cd "$ROOT/web" && npm install && npm run dev
  → http://127.0.0.1:3000  키 있으면 Google 로그인 → /account
  키 없으면 설정 안내만. 비밀키는 커밋하지 않음.

hub (ppomi-hub, 카탈로그, Clerk 세션 없음):
  cd "$ROOT/hub" && npm install && npm test

body AX (ppomi-body-macos, PR #43 / main — Node, 앱 안 아님):
  PPOMI_BODY_LIVE=1 node --experimental-strip-types "$ROOT/packages/ppomi-body-macos/example/src/main.ts"
  손쉬운 사용(+ Safari/Chrome Automation)을 node를 띄운 앱(Terminal·iTerm·Cursor)에 허용.

Swift AX (MacUI.swift)는 PR #12에 있고 main에 없다. 다음 PR이 그걸 뽀미.app MCP에 넣는다.
EOF
}

chosen_app() {
    if [ "$FORCE_BUILD" -eq 1 ]; then
        echo "$APP_DIST"
        return
    fi
    if [ -d "$APP_INSTALLED_KO" ]; then
        echo "$APP_INSTALLED_KO"
        return
    fi
    if [ -d "$APP_INSTALLED_EN" ]; then
        echo "$APP_INSTALLED_EN"
        return
    fi
    echo "$APP_DIST"
}

self_check() {
    out=$(sh "$0" --dry-run) || { echo "self-check: dry-run failed" >&2; exit 1; }
    echo "$out" | grep -q 'ppomi-web' || { echo "self-check: missing ppomi-web" >&2; exit 1; }
    echo "$out" | grep -q 'ppomi-hub' || { echo "self-check: missing ppomi-hub" >&2; exit 1; }
    echo "$out" | grep -q 'ppomi-body-macos' || { echo "self-check: missing ppomi-body-macos" >&2; exit 1; }
    echo "$out" | grep -q '/account' || { echo "self-check: missing /account" >&2; exit 1; }
    echo "$out" | grep -q 'make-app.sh' || { echo "self-check: missing make-app.sh" >&2; exit 1; }
    echo "$out" | grep -qi 'ppomi-mac-shell' && { echo "self-check: invented package name" >&2; exit 1; }
    echo "$out" | grep -qi 'ppomi-app-shell' && { echo "self-check: invented package name" >&2; exit 1; }
    if SIGN_ID=fake sh "$0" --dry-run >/dev/null 2>&1; then
        echo "self-check: SIGN_ID should have been refused" >&2
        exit 1
    fi
    echo "open-mac-shell self-check: PASS"
}

FORCE_BUILD=0
DRY_RUN=0
for arg in "$@"; do
    case "$arg" in
        --help|-h) usage; exit 0 ;;
        --build) FORCE_BUILD=1 ;;
        --dry-run) DRY_RUN=1 ;;
        --self-check) self_check; exit 0 ;;
        *) echo "unknown argument: $arg (use --help)" >&2; exit 2 ;;
    esac
done

refuse_store_signing
print_operator
echo
APP=$(chosen_app)
if [ "$FORCE_BUILD" -eq 1 ]; then
    echo "app: $APP_DIST  (--build → scripts/make-app.sh, 공증 없음)"
else
    echo "app: $APP"
fi

if [ "$DRY_RUN" -eq 1 ]; then
    exit 0
fi

if [ "$(uname -s)" != "Darwin" ]; then
    echo "Mac에서 실행하세요. 이 환경은 Swift AppKit을 빌드하지 않습니다. --dry-run / --self-check 는 여기에서도 됩니다." >&2
    exit 2
fi

if [ "$FORCE_BUILD" -eq 1 ] || [ ! -d "$APP" ]; then
    command -v swift >/dev/null 2>&1 || { echo "swift가 없습니다. Xcode CLT 설치 후 다시 실행하세요." >&2; exit 2; }
    echo "building $APP_DIST via scripts/make-app.sh …"
    "$ROOT/scripts/make-app.sh"
    APP="$APP_DIST"
fi

if [ ! -d "$APP" ]; then
    echo "앱 번들이 없습니다: $APP" >&2
    exit 2
fi

open "$APP"
echo "opened $APP"
