# storybook

`npm run storybook` — 작업대·분개·증거(OCR)·증빙 잠금.

증빙 잠금(2026-09-12, [MZZ-73](https://linear.app/muilyzz/issue/MZZ-73) · [MZZ-70](https://linear.app/muilyzz/issue/MZZ-70)): http://localhost:6006 → 사이드바 **증빙/**. 툴바 **스타일 = 뽀미 테마**.

- http://localhost:6006/?path=/story/증빙-panel--lock — Panel 큰 면: 서버 메타 · presence · 그리드 · 링크 4상태 · 다단
- http://localhost:6006/?path=/story/증빙-panel--local-open — 자기 기기 즉시 열기
- http://localhost:6006/?path=/story/증빙-panel--peer-online — 피어 온라인 E2E
- http://localhost:6006/?path=/story/증빙-panel--peer-offline — 피어 오프라인 비활성
- http://localhost:6006/?path=/story/증빙-presence--devices — Mac/Win/Phone 온라인 표시
- http://localhost:6006/?path=/story/증빙-links--four-states — 링크 4상태
- http://localhost:6006/?path=/story/증빙-links--eligible — 적격 4종 · 연결/미연결
- http://localhost:6006/?path=/story/증빙-links--auxiliary — 보조만(스냅샷/StepResult). 적격 아님
- http://localhost:6006/?path=/story/증빙-grid--device-time — 기기×시각 그리드
- http://localhost:6006/?path=/story/증빙-preview--hover — hover 미리보기 (클릭 아님)
- http://localhost:6006/?path=/story/증빙-preview--spinner — 기기간 수신 중 스피너
- http://localhost:6006/?path=/story/증빙-preview--encrypted-cache — 오프라인 암호문 캐시
- http://localhost:6006/?path=/story/증빙-preview--session-cache — E2E 1회 후 세션 미리보기 즉시
- http://localhost:6006/?path=/story/증빙-servermeta--journal — 분개 · 숫자 · 메타 링크

공개 API는 `EvidenceFleet.Panel` + `Presence` / `Links` / `Grid` / `Preview` / `ServerMeta`. Panel은 조립만. 서버 칸은 분개·숫자·불투명 ref. 메타 링크도 같은 hover 미리보기. 기기 미부착은 빈 미리보기(가짜 이미지 없음). 링크 라벨은 `Mac · 세금계산서 · 9.12 01:10`. 로컬 파일 키는 `(기기, collectedAtMs)` — ms. 내부 id는 툴바 **debug** 기본 끔. 그리드는 기기(행)×시각(열); 온라인·열림은 채운 칸, 오프·미부착은 빈 칸. 스냅샷·엑셀은 기기에 두고 스토리에 바이트를 넣지 않는다. hover=미리보기, 클릭=열기/받기. 피어 온라인이면 E2E(수신 스피너) 후 세션 캐시. 오프면 비활성 또는 암호문 캐시 안내. 앱 wire·실제 E2E 암호는 없음.

기존 OCR 스티치(은행·인바디·임대)는 사이드바 **증거**. 테스트: `cd storybook && node --test evidence-fleet.test.mjs`.
