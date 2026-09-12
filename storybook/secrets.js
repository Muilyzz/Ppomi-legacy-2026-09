// storybook/secrets.js — 키체인/로컬 시크릿 블롭을 키–값 트리로 본다. 스키마별 폼 없음.
// 잠김: 잎 마스킹 + 접힘. 뒷 4자리(****뒷4)는 계좌 키 허용 목록(accountKeys)에 있는 잎만; 값 모양(숫자 길이)은 근거가 아니라
// OTP·PIN·전화·주민·사업자 모양의 숫자와 숫자 잎은 전부 ••••. 열림(스토리북은 인증 흉내): 원문 + 펼침. 복사는 onCopy 스텁(로컬만).
// 앱 셸 wire는 MZZ-44 이후. CSS 없음: .sec .nav .meta .lbl .mute code details.
(function (root) {
'use strict';

var ACCOUNT_KEYS = ['account', 'accountNumber', 'accountNo', 'acct', '계좌', '계좌번호'];
var MAX_DEPTH = 32;

function esc(s) { return String(s).replace(/[&<>"']/g, function (c) { return {'&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#x27;'}[c]; }); }
function isObj(v) { return v && typeof v === 'object'; }
function unwrap(v) {
  if (typeof v !== 'string') return v;
  var t = v.trim();
  if (t.charAt(0) !== '{' && t.charAt(0) !== '[') return v;
  try { return JSON.parse(t); } catch (e) { return v; }
}
function digitsOf(v) { return String(v).replace(/\D/g, ''); }
function last4(v) { var d = digitsOf(v); return d.length >= 4 ? '****' + d.slice(-4) : null; }
function normKey(k) { return String(k).toLowerCase().replace(/[\s_-]/g, ''); }
/** 마지막 경로 조각의 끝 토큰(`ppomi/kb/account` → `account`), 대소문자·공백·_-를 무시한다. */
function keyToken(path) { return normKey(String(path[path.length - 1] || '').split(/[\/.:]/).pop()); }
/** 계좌 키 허용 목록에 있는 잎만 뒷 4자리를 보인다. `accountName`처럼 부분 일치는 통과하지 않는다. */
function accountish(path, v, accountKeys) {
  var allow = (accountKeys || ACCOUNT_KEYS).map(normKey);
  return allow.indexOf(keyToken(path)) !== -1 && !!last4(v);
}
function maskLeaf(path, v, accountKeys) { return accountish(path, v, accountKeys) ? last4(v) : '••••'; }

function eachLeaf(value, path, fn) {
  if (path.length >= MAX_DEPTH) return;
  value = unwrap(value);
  if (Array.isArray(value)) { value.forEach(function (x, i) { eachLeaf(x, path.concat(i), fn); }); return; }
  if (isObj(value)) { Object.keys(value).forEach(function (k) { eachLeaf(value[k], path.concat(k), fn); }); return; }
  fn(path, value);
}
function atPath(value, path) {
  var cur = unwrap(value);
  for (var i = 0; i < path.length; i++) { if (cur == null) return undefined; cur = unwrap(cur[path[i]]); }
  return cur;
}
function chipsOf(value, accountKeys) {
  var out = [];
  eachLeaf(value, [], function (path, leaf) {
    if (!accountish(path, leaf, accountKeys)) return;
    var key = path.filter(function (p) { return String(p).indexOf('ppomi/') === 0; })[0] || path[path.length - 1];
    out.push({path: path, key: String(key), chip: last4(leaf)});
  });
  return out;
}

function kidKeys(value) { return Array.isArray(value) ? value.map(function (_, i) { return i; }) : Object.keys(value); }
function node(value, path, st) {
  if (path.length >= MAX_DEPTH) return '<span class="lbl">…</span> <span class="mute">…</span>';
  value = unwrap(value);
  if (isObj(value)) {
    var keys = kidKeys(value), label = path.length ? path[path.length - 1] : 'blob';
    return '<details' + (st.expanded ? ' open' : '') + '><summary>' + esc(label) + ' <small class="meta">' + keys.length + '</small></summary><ul>' +
      keys.map(function (k) { return '<li>' + node(value[k], path.concat(k), st) + '</li>'; }).join('') + '</ul></details>';
  }
  var key = path.length ? path[path.length - 1] : 'value';
  var secret = typeof value === 'string' || typeof value === 'number';
  var text = value == null ? '—' : secret && !st.unlocked ? maskLeaf(path, value, st.accountKeys) : String(value);
  var copy = st.unlocked && secret ? ' <button type="button" data-copy="' + esc(JSON.stringify(path)) + '">복사</button>' : '';
  return '<span class="lbl">' + esc(key) + '</span> ' +
    (st.unlocked || !secret ? '<code>' + esc(text) + '</code>' : '<span class="mute">' + esc(text) + '</span>') + copy;
}

function html(st) {
  var chips = chipsOf(st.blob, st.accountKeys).map(function (c) { return '<small class="meta">' + esc(c.key) + ' · ' + esc(c.chip) + '</small>'; }).join(' ');
  return '<div class="sec">로컬 시크릿 <span class="r"><small class="meta">' + (st.unlocked ? '열림' : '잠김') + '</small></span></div>' +
    (chips ? '<p>' + chips + '</p>' : '') +
    '<nav class="nav" aria-label="열람"><button type="button" data-unlock>' + (st.unlocked ? '잠그기' : '인증하고 열기') + '</button></nav>' +
    (st.blob == null ? '<p class="meta">시크릿 없음</p>' : node(st.blob, [], st));
}

function mount(el, opts) {
  var st = {blob: null, unlocked: false, expanded: false, accountKeys: ACCOUNT_KEYS};
  Object.keys(opts || {}).forEach(function (k) { if (opts[k] !== undefined) st[k] = opts[k]; });
  function draw() { el.innerHTML = html(st); }
  function set(patch) { Object.keys(patch).forEach(function (k) { st[k] = patch[k]; }); draw(); }
  el.addEventListener('click', function (ev) {
    var b = ev.target.closest('[data-unlock],[data-copy]');
    if (!b || !el.contains(b)) return;
    if (b.hasAttribute('data-unlock')) {
      var next = !st.unlocked;
      set({unlocked: next, expanded: next});
      if (st.onUnlock) st.onUnlock(next);
    } else if (st.unlocked) {
      var path = JSON.parse(b.getAttribute('data-copy'));
      var v = atPath(st.blob, path);
      if (st.onCopy) st.onCopy(path, v == null ? '' : String(v));
    }
  });
  draw();
  return {set: set, state: function () { return st; }};
}

root.Secrets = {ACCOUNT_KEYS, MAX_DEPTH, unwrap, last4, keyToken, accountish, maskLeaf, eachLeaf, atPath, chipsOf, html, mount};
})(globalThis);
