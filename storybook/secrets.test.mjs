// secrets.js — 마스킹·칩·JSON 풀기·잠김/열림 마크업. DOM 없이 돈다: npm test
import test from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import './secrets.js';
const S = globalThis.Secrets;
const blob = JSON.parse(readFileSync(new URL('./secrets-fixture.json', import.meta.url), 'utf8'));

test('픽스처는 합성 프로브만: 실키체인 원문 없음', () => {
  assert.equal(blob.synthetic, true);
  assert.equal(blob.source, 'storybook-probe');
  assert.match(blob.items['ppomi/probe/session-blob'].payload.token, /^probe-/);
  assert.equal(blob.items['ppomi/kb-star-biz/account'], '001234567890');
});

test('last4·계좌 칩: secretEvidence 와 같은 ****뒷4, 짧은 PIN은 칩 없음', () => {
  assert.equal(S.last4('001234567890'), '****7890');
  assert.ok(S.accountish(['accountNumber'], '009876543210'));
  assert.ok(S.accountish(['ppomi/kb-star-biz/account'], '001234567890'));
  assert.ok(!S.accountish(['pins'], '0000'));
  assert.ok(!S.accountish(['token'], 'probe-not-a-real-token'));
  const chips = S.chipsOf(blob);
  assert.deepEqual(chips.map((c) => [c.key, c.chip]), [
    ['ppomi/kb-star-biz/account', '****7890'],
    ['ppomi/probe/json-string', '****3210'],
  ]);
});

test('JSON 문자열은 트리로 풀고, 경로로 다시 읽는다', () => {
  assert.deepEqual(S.unwrap('{"a":1}'), {a: 1});
  assert.equal(S.unwrap('not-json'), 'not-json');
  assert.equal(S.atPath(blob, ['items', 'ppomi/probe/json-string', 'bank']), 'kb-probe');
  assert.equal(S.atPath(blob, ['items', 'ppomi/kb-star-biz/account']), '001234567890');
});

test('잠김 HTML: 원문 없고 접힘, 칩만. 열림: 원문 + open', () => {
  const locked = S.html({blob, unlocked: false, expanded: false});
  const opened = S.html({blob, unlocked: true, expanded: true});
  assert.match(locked, />잠김</);
  assert.match(locked, /인증하고 열기/);
  assert.match(locked, /ppomi\/kb-star-biz\/account · \*\*\*\*7890/);
  assert.doesNotMatch(locked, /001234567890/);
  assert.doesNotMatch(locked, /probe-not-a-real-token/);
  assert.doesNotMatch(locked, /009876543210/);
  assert.doesNotMatch(locked, /<details open/);
  assert.match(locked, /••••/);
  assert.match(opened, />열림</);
  assert.match(opened, /잠그기/);
  assert.match(opened, /001234567890/);
  assert.match(opened, /probe-not-a-real-token/);
  assert.match(opened, /<details open/);
  assert.match(opened, /data-copy="/);
  assert.doesNotMatch(locked, /data-copy="/);
  assert.doesNotMatch(locked, /<style/);
});
