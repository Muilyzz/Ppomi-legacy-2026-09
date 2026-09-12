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

test('뒷 4자리는 계좌 키 허용 목록의 잎만: 대소문자·_-·경로 끝 토큰, accountName 은 아니다, 목록은 옵션으로 바꾼다', () => {
  for (const key of ['account', 'accountNumber', 'ACCOUNT_NUMBER', 'account-no', 'acct', '계좌', '계좌번호', 'ppomi/kb-probe/account', 'bank.accountNumber']) {
    assert.equal(S.maskLeaf([key], '001234567890'), '****7890', key);
    assert.deepEqual(S.chipsOf({[key]: '001234567890'}).map((c) => c.chip), ['****7890'], key);
  }
  for (const key of ['accountName', 'accounts', 'account-holder', 'subaccountish', 'token']) {
    assert.equal(S.maskLeaf([key], '001234567890'), '••••', key);
    assert.deepEqual(S.chipsOf({[key]: '001234567890'}), [], key);
  }
  assert.equal(S.keyToken(['items', 'ppomi/kb-probe/account']), 'account');
  assert.equal(S.maskLeaf(['account'], '12'), '••••', '4자리 미만이면 뒷 4자리도 없다');
  // 허용 목록 옵션: iban 만 계좌 키로 보는 블롭
  const custom = {iban: 'DE00 1234 5678 9012', account: '001234567890'};
  assert.equal(S.maskLeaf(['iban'], custom.iban, ['iban']), '****9012');
  assert.equal(S.maskLeaf(['account'], custom.account, ['iban']), '••••');
  assert.deepEqual(S.chipsOf(custom, ['iban']).map((c) => [c.key, c.chip]), [['iban', '****9012']]);
  const locked = S.html({blob: custom, unlocked: false, accountKeys: ['iban']});
  assert.match(locked, /iban · \*\*\*\*9012/);
  assert.doesNotMatch(locked, /7890/);
});

test('계좌 키가 아닌 숫자 값은 모양이 어떻든 전부 가린다: OTP·PIN·전화·주민·사업자 모양, 숫자 잎, accountName', () => {
  // 합성 플레이스홀더만: 실제 번호가 아니다.
  const shapes = {
    otp: '123456', pin: '654321', phone: '010-1234-5678', rrn: '900101-1234567', bizno: '123-45-67890',
    card: '4111 1111 1111 1111', count: 123456, accountName: '합성 통장 1234', note: '1234 5678 90',
  };
  for (const [key, value] of Object.entries(shapes)) {
    assert.equal(S.accountish([key], value), false, key);
    assert.equal(S.maskLeaf([key], value), '••••', key);
  }
  assert.deepEqual(S.chipsOf(shapes), [], '칩 행에 올라오지 않는다');
  const locked = S.html({blob: shapes, unlocked: false, expanded: true});
  for (const value of Object.values(shapes)) {
    const digits = String(value).replace(/\D/g, '');
    assert.doesNotMatch(locked, new RegExp(digits.slice(-4)), `${value}: 뒷 4자리도 없다`);
  }
  assert.equal((locked.match(/••••/g) ?? []).length, Object.keys(shapes).length);
  assert.doesNotMatch(locked, /\*\*\*\*/);
});

test('HTML 이스케이프: 적대적 키·값·중첩 JSON 문자열이 마크업이 되지 않고, data-copy 경로는 복원된다', () => {
  const hostileKey = '<img src=x onerror=alert(1)>';
  const hostileVal = '"><img src=x onerror=alert(2)><script>alert(3)</script>';
  const blob = {
    [hostileKey]: hostileVal,
    'a"b\'c&d': {arr: ['<svg onload=alert(4)>', 12345678]},
    json: JSON.stringify({'</summary></details><p>x</p>': hostileVal}),
  };
  for (const st of [{blob, unlocked: false, expanded: false}, {blob, unlocked: true, expanded: true}]) {
    const h = S.html(st);
    assert.doesNotMatch(h, /<img|<script|<svg|<\/details><p>x/i, `unlocked=${st.unlocked}`);
    assert.match(h, /&lt;img src=x onerror=alert\(1\)&gt;/);
    assert.match(h, /&lt;\/summary&gt;&lt;\/details&gt;/);
    assert.doesNotMatch(h, /onerror=alert\(\d\)>/, '이스케이프되지 않은 핸들러 없음');
  }
  const opened = S.html({blob, unlocked: true, expanded: true});
  const attrs = [...opened.matchAll(/data-copy="([^"]*)"/g)].map((m) => m[1]);
  assert.ok(attrs.length >= 4);
  const decode = (s) => s.replace(/&quot;/g, '"').replace(/&#x27;/g, "'").replace(/&lt;/g, '<').replace(/&gt;/g, '>').replace(/&amp;/g, '&');
  const paths = attrs.map((a) => JSON.parse(decode(a)));
  assert.deepEqual(paths[0], [hostileKey]);
  assert.deepEqual(paths[1], ['a"b\'c&d', 'arr', 0]);
  assert.equal(S.atPath(blob, paths[0]), hostileVal);
  assert.equal(S.atPath(blob, paths[1]), '<svg onload=alert(4)>');
});

test('깊이는 32에서 …로 자르고 던지지 않는다', () => {
  let deep = 'leaf';
  for (let i = 0; i < 40; i++) deep = {d: deep};
  const h = S.html({blob: deep, unlocked: true, expanded: true});
  assert.match(h, /<span class="lbl">…<\/span> <span class="mute">…<\/span>/);
  assert.doesNotMatch(h, /leaf/);
  assert.equal((h.match(/<details/g) ?? []).length, S.MAX_DEPTH);
  let arr = [];
  for (let i = 0; i < 5000; i++) arr = [arr];
  assert.doesNotThrow(() => S.html({blob: arr, unlocked: false}));
  assert.deepEqual(S.chipsOf(deep), []);
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
  assert.match(locked, /class="secrets"/);
  assert.match(locked, /class="jtitle"/);
  assert.match(locked, /class="card"/);
  assert.match(locked, /<ul>/);
  assert.match(locked, /••••/);
  assert.match(opened, />열림</);
  assert.match(opened, /잠그기/);
  assert.match(opened, /001234567890/);
  assert.match(opened, /probe-not-a-real-token/);
  assert.match(opened, /<details open/);
  assert.match(opened, /data-copy="/);
  assert.match(opened, /class="entry"/);
  assert.doesNotMatch(locked, /data-copy="/);
  assert.doesNotMatch(locked, /class="entry"/);
  assert.doesNotMatch(locked, /<style/);
});
