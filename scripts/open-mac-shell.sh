#!/bin/sh
# Open the existing 뽀미.app Mac shell. No new package. No store / notarized signing.
# Finder: double-click scripts/open-mac-shell.command
# CLI:    scripts/open-mac-shell.sh [--build] [--dry-run] [--self-check]
# Test in the main app chat (one line, not the Home → KB button), not packages/*/example.
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
테스트는 메인 앱에서 한다 (packages/*/example 아님).
빌드: LOCAL_SIGN_ID=… $ROOT/scripts/make-app.sh  →  dist/Ppomi.app (공증·스토어 서명 없음)

CEO 한 줄:
  1. 이 스크립트 또는 scripts/open-mac-shell.command 로 뽀미.app 을 연다.
  2. 나(아바타)에서 Google 로그인(선택). 작업대가 열리면 이 Mac 이 플릿에 붙는다 (DeviceRegistry.attach).
  3. 채팅에 **KB 사업자 계좌 읽어줘** 라고 보낸다. **Home → KB** 버튼은 누르지 않는다.
     에이전트가 path_cold_start(app: kb-enterprise) 를 호출한다.
     iPhone 미러링이 붙은 뒤 Home(phone_key home) → KB스타기업뱅킹 열기(phone_open).
     Face ID·로그인 화면에서 멈춘다. 계좌·비밀은 읽지 않는다.
     손·눈이 없으면 권한 허용 CTA(시스템 프롬프트)가 먼저다. 거절 뒤에만 시작하기.
  같은 동작: Ppomi --mcp 에 같은 한 줄을 보내 path_cold_start(app: kb-enterprise)

web / Clerk (ppomi-web, who — 앱 로그인과 별개):
  cd "$ROOT/web" && test -f .env.local || cp .env.example .env.local
  cd "$ROOT/web" && npm install && npm run dev
  → http://127.0.0.1:3000  키 있으면 Google 로그인 → /account
  키 없으면 설정 안내만. 비밀키는 커밋하지 않음.

hub (ppomi-hub, 카탈로그, Clerk 세션 없음):
  cd "$ROOT/hub" && npm install && npm test
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
    echo "$out" | grep -q 'path_cold_start' || { echo "self-check: missing path_cold_start" >&2; exit 1; }
    echo "$out" | grep -q 'KB 사업자 계좌' || { echo "self-check: missing chat line" >&2; exit 1; }
    echo "$out" | grep -q 'Home → KB' || { echo "self-check: missing Home → KB" >&2; exit 1; }
    echo "$out" | grep -q 'example 아님' || { echo "self-check: missing main-app-not-example" >&2; exit 1; }
    echo "$out" | grep -q '권한 허용 CTA' || { echo "self-check: missing permission CTA" >&2; exit 1; }
    echo "$out" | grep -q '시작하기' || { echo "self-check: missing 시작하기 fallback" >&2; exit 1; }
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
