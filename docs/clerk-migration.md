# Clerk 본인증 이전 (MZZ-39)

슬라이스 1 **스파이크**. 브리지를 증명하고, Mac / iPad / Android / 에이전트 클라이언트를 아직 옮기지 않는다.

잠금:

- Clerk가 **본인증**이다. 로그인·프로필·연결 계정·이후 조직(가족/회사)은 Clerk UX.
- IdP: Google, Apple, Microsoft. 이메일은 보조로 나중에.
- Supabase는 Postgres · RLS · Realtime · Vault. Clerk 세션 JWT를 검증해 RLS에 쓴다.
- 기록 암호는 서버 키 / Vault (MZZ-27). Clerk 메타데이터에 기록 키를 넣지 않는다.
- 금융 최종제출 HITL · path grant는 [MZZ-38](https://linear.app/muilyzz/issue/MZZ-38). Clerk가 대체하지 않는다.
- 공개 카탈로그 허브(`hub/`)의 KV API는 그대로. 이 슬라이스는 `web/` Next 앱만 깐다.

## 오늘 코드가 하는 일

| 표면 | 인증 |
|---|---|
| Mac · iPad | Supabase Auth Google OAuth (PKCE), 콜백 `ppomi://auth` |
| Android · 에이전트 스모크 · `shared-server.py` | 기기 이메일/비밀번호 `grant_type=password` |
| 에이전트 서버 | Bearer Supabase access token → `ppomi_context` |
| `hub/` | 세션 없음 (공개 카탈로그) |
| Windows | 네이티브 Auth 없음. Parallels 게스트는 Mac 세션이 조종 |

RLS/RPC는 `auth.uid()` (UUID, `auth.users`)와 `ppomi_members.auth_user_id` / `ppomi_devices.auth_user_id`에 묶여 있다.

## 목표 구조

```text
브라우저 / 이후 네이티브
        │  Clerk SignIn · UserButton · UserProfile
        ▼
   Clerk session JWT   (sub = user_…, role = authenticated)
        │  createClient({ accessToken: () => session.getToken() })
        ▼
Supabase API  ── JWKS(Clerk)로 JWT 검증
        │
        ▼
Postgres RLS  (select auth.jwt() ->> 'sub')
        │
Vault / 서버 키 암호문   ← 신원과 분리 (MZZ-27)
```

`auth.uid()`는 `sub`를 uuid로 캐스팅한다. Clerk id(`user_2…`)에서는 NULL이거나 `22P02`가 난다. **RLS는 `auth.jwt()->>'sub'`를 text로 비교한다.**

구 Clerk JWT 템플릿(프로젝트 JWT secret을 Clerk에 붙여 HS256을 찍는 방식)은 2025-04-01 폐기. 스파이크는 **서드파티 Clerk(JWKS)** 만 증명한다. 템플릿은 롤백 메모에만 남긴다.

## `web/` 스파이크

Next.js App Router + `@clerk/nextjs`.

| 경로 | 역할 |
|---|---|
| `/` | 키 있으면 안내, 없으면 설정 패널 |
| `/sign-in` · `/sign-up` | Clerk `<SignIn />` / `<SignUp />` (Hosted도 가능, 기본은 임베디드) |
| `/account` | `auth.protect()` + UserButton. Clerk `sub` 표시 |
| `/account/profile` | `<UserProfile />` (연결 계정 UI는 여기) |

키가 없으면 ClerkProvider/middleware는 켜지지 않는다. 빌드·테스트는 비밀 없이 통과해야 한다.

```sh
cd web
cp .env.example .env.local   # 실제 키만 사람이 붙인다
npm install && npm test && npm run typecheck
npm run dev
```

### 환경 변수

`.env.example`에 플레이스홀더만 있다. **실제 키를 만들지 않았고, 커밋하지도 않는다.**

| 이름 | 필수 | 출처 |
|---|---|---|
| `NEXT_PUBLIC_CLERK_PUBLISHABLE_KEY` | 예 | Clerk Dashboard → API Keys → `pk_test_…` / `pk_live_…` |
| `CLERK_SECRET_KEY` | 예 | 같은 화면 → Secret key `sk_test_…` / `sk_live_…`. 서버만. |
| `NEXT_PUBLIC_CLERK_SIGN_IN_URL` | 경로 | `/sign-in` |
| `NEXT_PUBLIC_CLERK_SIGN_UP_URL` | 경로 | `/sign-up` |
| `NEXT_PUBLIC_CLERK_AFTER_SIGN_IN_URL` | 경로 (deprecated fallback) | `/account` — `SignIn`/`ClerkProvider` use `forceRedirectUrl` |
| `NEXT_PUBLIC_CLERK_AFTER_SIGN_UP_URL` | 경로 (deprecated fallback) | `/account` — same |
| `NEXT_PUBLIC_CLERK_AFTER_SIGN_OUT_URL` | 경로 | `/` |
| `CLERK_WEBHOOK_SECRET` | 슬라이스 2+ | Webhook signing secret `whsec_…`. 지금 핸들러 없음. |
| `NEXT_PUBLIC_SUPABASE_URL` | 선택 | 기존 프로젝트 `https://nafutfqfbbmknzmyspus.supabase.co` |
| `NEXT_PUBLIC_SUPABASE_ANON_KEY` | 선택 | publishable/anon. `service_role` 금지. |

운영자가 붙여야 하는 비밀은 위 두 Clerk 키(그리고 나중에 webhook)뿐이다. Google/Apple/Microsoft 클라이언트 시크릿은 **Clerk Dashboard에만** 두고 저장소에 넣지 않는다.

## Clerk Dashboard 체크리스트

1. [dashboard.clerk.com](https://dashboard.clerk.com)에서 애플리케이션 생성 (이름 예: `ppomi`).
2. API Keys에서 Publishable / Secret을 복사해 `web/.env.local`에만 둔다.
3. **SSO connections**
   - Google: Cloud Console OAuth 클라이언트. Clerk가 준 Redirect URI.
   - Apple: Services ID, Team ID, Key ID, `.p8`. Clerk Return URL.
   - Microsoft: Azure AD 앱 클라이언트 ID/시크릿. Clerk Redirect URI.
   - Email/password는 아직 켜지 않아도 된다.
4. [Connect with Supabase](https://dashboard.clerk.com/setup/supabase)로 세션 토큰에 `"role": "authenticated"`를 넣는다. 못 쓰면 Sessions → Customize session token에 같은 claim.
5. Organizations는 슬라이스 4 (Family org → Work org). 지금 켜지 않아도 스파이크는 성립한다.
6. Webhook (`user.created` 등)은 슬라이스 2+. 엔드포인트는 아직 없다.

## Supabase: Clerk JWT → RLS

1. 프로젝트 [ppomi](https://supabase.com/dashboard/project/nafutfqfbbmknzmyspus) → Authentication → Sign in / Third-party → **Clerk**.
2. Clerk Frontend API 도메인 (`<app>.clerk.accounts.dev` 또는 커스텀 도메인). 지어내지 말 것.
3. 로컬 CLI는 `supabase/config.toml`의 `[auth.third_party.clerk]`를 **실제 도메인을 알게 된 뒤에만** `enabled = true`로 켠다. 지금은 `false`.
4. 클라이언트가 Clerk 세션 JWT를 그대로 보낸다.

```ts
createClient(url, anonKey, {
  accessToken: async () => (await session.getToken()) ?? undefined,
})
```

`web/src/lib/clerk-supabase.ts`의 `supabaseClerkAccessToken`이 이 모양이다. `@supabase/supabase-js`는 아직 넣지 않았다.

### RLS 스케치

```sql
-- Clerk sub 는 text. auth.uid() 를 쓰지 않는다.
using (clerk_user_id = (select auth.jwt() ->> 'sub'));

-- PostgREST 역할
-- JWT 에 "role": "authenticated" 가 있어야 TO authenticated 가 맞다.
```

기존 `ppomi_private_device()` 등은 `auth.uid()`를 본다. 슬라이스 5 전에 이 RPC를 바꾸면 현재 Google/비밀번호 기기가 깨진다. 스파이크는 **새 초안 테이블**만 스케치한다.

선택 초안: [`supabase/drafts/clerk_user_map.sql`](../supabase/drafts/clerk_user_map.sql)

- `ppomi_clerk_identities(clerk_user_id text, auth_user_id uuid)`
- `db push` 대상이 아님. 슬라이스 5 백필 때 적용.
- 자기 `sub` 행만 읽는 RLS 증명 정책 포함.

## 호출 지점 목록 (슬라이스 2–3)

정규 목록은 `web/src/lib/auth-inventory.ts` (테스트가 표면별로 고정).

### Mac

| 파일 | 방식 |
|---|---|
| `Ppomi/Sources/Ppomi/Shared/SupabaseAuth.swift` | Google PKCE `/auth/v1/authorize` · `/token` · refresh |
| `…/GoogleAccount.swift` | 시스템 로그인 창. JWT `sub`가 **UUID**여야 등록 |
| `…/SharedServerClient.swift` | refresh 또는 legacy password + `ppomi_context` |
| `…/SharedServerConfiguration.swift` | 옛 기기 파일 5필드 |
| `…/Views/MeSheet.swift` | 구글 로그인 UI |
| `…/PpomiApp.swift` | 공유·키 랩 시작 |
| `…/Serve/SharedTools.swift` | MCP `shared_status` |
| `…/Shared/SharedRecordVault.swift` | 같은 세션으로 암호문 RPC |

### iPad

| 파일 | 방식 |
|---|---|
| `iPad/Sources/PadAuth.swift` | 같은 PKCE |
| `iPad/Sources/PadBridge.swift` | refresh + `apikey` + `X-Ppomi-Device` |
| `iPad/Sources/PpomiPad.swift` | 로그인 버튼 |
| `iPad/Sources/PadSettings.swift` | URL/키 |
| `iPad/Sources/PadVault.swift` | 기록 읽기 (인증 공급자 아님) |

### Android

| 파일 | 방식 |
|---|---|
| `…/SupabaseClient.java` | password grant. 토큰은 JS에 안 줌 |
| `…/SupabaseSettings.java` | 기기 설정. `service_role` 거부 |
| `…/SharedTaskController.java` | 공유 작업 RPC |
| `…/VoiceServerClient.java` | 에이전트 Bearer |
| `…/DebugProvisioningActivity.kt` | 디버그 설정 가져오기 |

### 허브 · Windows · 에이전트 · 스크립트

| 표면 | 상태 |
|---|---|
| `hub/` | 세션 없음. 슬라이스 2가 이 Next 앱으로 허브 세션을 연다. footprint API는 그대로. |
| Windows | Auth 클라이언트 없음. Mac이 게스트를 조종. |
| `agent/server/handler.ts` | Bearer + `ppomi_context` |
| `agent/scripts/*-smoke.ts` | password grant |
| `scripts/shared-server.py` | CLI admin 사용자 생성 + password grant |

슬라이스 2: 웹 세션만 Clerk. 슬라이스 3: Mac/iPad 딥링크·토큰 교환, Android password grant 교체. `X-Ppomi-Device`와 기기 등록 RPC는 남긴다.

## 하지 않는 일 (이 PR)

- Mac/iPad/Android 로그인 UI 교체
- `auth.uid()` RPC를 Clerk `sub`로 일괄 변경
- `hub/` Vercel KV를 Next로 재작성
- path/body 플레이북 드라이버 (MZZ-38)
- 조직, webhook 핸들러, `auth.users` 백필
- Clerk에 기록 암호 키를 넣거나 E2E로 되돌리기

## 롤백

1. `web/`을 배포에서 빼고 `hub/` 랜딩만 둔다. 네이티브는 그대로 Google/비밀번호.
2. Supabase Third-party Clerk를 끄면 Clerk JWT는 `authenticated`가 되지 않는다. 기존 Supabase Auth 토큰은 영향 없다.
3. `supabase/drafts/clerk_user_map.sql`을 적용했다면 테이블만 drop. 기존 `ppomi_*` 행은 건드리지 말 것.
4. JWT 템플릿+공유 JWT secret으로 돌아가지 말 것. secret 유출·로테이션 다운타임이 이유다.
5. `CLERK_*`를 저장소에 커밋한 적이 있으면 키를 회전하고 git history를 검사한다. 이 스파이크는 예시 값만 넣는다.

## 검증

```sh
cd web && npm test && npm run typecheck
```

실제 Google/Apple/Microsoft 로그인은 Dashboard 키 없이는 이 환경에서 증명하지 않는다. 증명하는 것: 키 없는 설정 패널, 보호 라우트 골격, `auth.jwt()->>'sub'` 매핑 테스트, 호출 지점 목록.

허브 회귀: `cd hub && npm test` (이 슬라이스에서 API를 바꾸지 않음).
