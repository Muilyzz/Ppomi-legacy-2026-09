# storybook

`cd storybook && npm run storybook`

값 종류(Facts)는 뷰어별로 나뉜다. `Facts.Panel` 은 스키마 값 종류만 보고 자식을 붙인다(표는 항상, 시간축은 time, 트리맵은 path+amount, 평면도는 place). 도메인 분기 없음.

- http://localhost:6006/?path=/story/값-종류-panel--building — 조립 · 건축물대장
- http://localhost:6006/?path=/story/값-종류-panel--loan — 조립 · 대출 약정
- http://localhost:6006/?path=/story/값-종류-panel--car — 조립 · 자동차등록증
- http://localhost:6006/?path=/story/값-종류-table--building — 표
- http://localhost:6006/?path=/story/값-종류-timeline--loan — 시간축
- http://localhost:6006/?path=/story/값-종류-treemap--holdings — 계층
- http://localhost:6006/?path=/story/값-종류-floorplan--spending — 평면도

테스트: `cd storybook && node --test facts.test.mjs`
