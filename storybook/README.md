# storybook

`npm run storybook` — 작업대·분개·증거(OCR)·증빙 잠금·절차·시크릿 트리.

증빙 잠금(2026-09-12, [MZZ-60](https://linear.app/muilyzz/issue/MZZ-60)): http://localhost:6006 → 사이드바 **증빙**. 툴바 **스타일 = 뽀미 테마**.

- http://localhost:6006/?path=/story/증빙--panel — 큰 면: 서버 메타 · presence · 링크 4상태 · 다단
- http://localhost:6006/?path=/story/증빙--local-open — 자기 기기 즉시 열기
- http://localhost:6006/?path=/story/증빙--peer-online — 피어 온라인 E2E
- http://localhost:6006/?path=/story/증빙--peer-offline — 피어 오프라인 비활성
- http://localhost:6006/?path=/story/증빙--eligible — 적격 4종 · 연결/미연결
- http://localhost:6006/?path=/story/증빙--auxiliary — 보조만(스냅샷/StepResult). 적격 아님
- http://localhost:6006/?path=/story/증빙--presence — Mac/Win/Phone 온라인 표시

서버 칸은 분개·숫자·`evidence_id`만. 스냅샷·엑셀은 기기에 두고 스토리에 바이트를 넣지 않는다. 링크는 로컬 즉시 / 피어 온라인이면 E2E / 오프면 비활성(또는 암호문 캐시 안내). 앱 wire·실제 E2E 암호는 없음.

기존 OCR 스티치(은행·인바디·임대)는 사이드바 **증거**. 테스트: `cd storybook && node --test evidence-fleet.test.mjs`.

시크릿 트리(잠김 마스킹 / 열림 원문)는 UI만. Ppomi.app wire는 [MZZ-44](https://linear.app/muilyzz/issue/MZZ-44) 앱 셸 이후.
