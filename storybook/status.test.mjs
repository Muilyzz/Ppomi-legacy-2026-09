// status.js — 큰 면 마크업·이스케이프·시크릿 슬롯. DOM 없이 돈다: npm test
import test from 'node:test';
import assert from 'node:assert/strict';
import './status.js';
import {title, phase, surfaces} from './status-fixture.js';
const S = globalThis.Status;

test('유휴 HTML: 제목·기기 카드·시크릿 슬롯. 원문 시크릿 없음', () => {
  const h = S.html({title, phase, surfaces});
  assert.match(h, /class="status"/);
  assert.match(h, /상태·비밀/);
  assert.match(h, />유휴</);
  assert.match(h, /기기·연결/);
  assert.match(h, /iPhone 미러링을 연결해 주세요/);
  assert.match(h, /Android · 연결 끊김/);
  assert.match(h, /data-secrets/);
  assert.doesNotMatch(h, /probe-not-a-real-token/);
  assert.doesNotMatch(h, /<style/);
});

test('알 수 없는 phase 는 유휴, 빈 기기는 안내, 적대적 라벨은 이스케이프', () => {
  assert.equal(S.phaseLabel('nope'), '유휴');
  assert.match(S.surfaceCards([]), /기기 없음/);
  const hostile = S.html({title: '<img src=x>', phase: 'idle', surfaces: [{id: 'x', label: '<svg>', hint: '"><script>alert(1)</script>'}]});
  assert.doesNotMatch(hostile, /<img|<svg|<script/i);
  assert.match(hostile, /&lt;img src=x&gt;/);
  assert.match(hostile, /&lt;svg&gt;/);
});
