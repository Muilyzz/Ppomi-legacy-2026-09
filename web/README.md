# ppomi-web

MZZ-39 slice 1 Clerk 스파이크. 공개 카탈로그 허브(`hub/`)는 그대로 두고, 여기만 Next + Clerk 본인증을 깐다.

```sh
cp .env.example .env.local   # 실제 pk_/sk_ 를 붙인다. 예시 값은 로그인되지 않는다.
npm install
npm test
npm run typecheck
npm run dev                  # http://127.0.0.1:3000
```

키 없이 띄우면 설정 안내만 보인다. 비밀키는 커밋하지 않는다. 설계·대시보드 체크리스트·롤백은 [docs/clerk-migration.md](../docs/clerk-migration.md).
