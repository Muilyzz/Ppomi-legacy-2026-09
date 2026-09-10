// Web/verify.js — 검증 파생. 패키지(명세 · 발자국 · 판정 장부)에서 (1) 단계별 최신 판정 요약(Swift VerificationStore.summary 와 같은 셈), (2) 값 종류 기록(기능 하나 = 기록 하나)을 만든다.
// 뷰가 아니다: 요약은 playbook.js 의 verification 으로, 기록은 facts.js 로 간다(대상/패키지/기능 = 경로, 미검증 단계 수 = 크기 → 남은 검증 일이 트리맵이 된다).
// 판정 장부 한 줄: {app, version, capability, step, outcome: ok|changed|fail, actual?, note?, at, by}. 판정은 버전에 묶인다 — 다른 버전은 stale 로만 센다.
(function (root) {
'use strict';
var TARGET = {browser: 'Mac 브라우저', windows: 'Windows'};
var F = function (key, title, type) { return {key: key, title: title, type: type}; };
var SCHEMA = {fields: [F('cap', '기능', 'text'), F('path', '대상/패키지/기능', 'path'), F('unverified', '미검증', 'amount'), F('total', '단계', 'amount'), F('ok', 'ok', 'amount'),
  F('changed', 'changed', 'amount'), F('fail', 'fail', 'amount'), F('walks', '발자국', 'amount'), F('last', '마지막 판정', 'time'), F('pkg', '플레이북', 'ref')]};

function summary(manifest, ledger) {
  var version = manifest.version || '', s = {version: version, total: 0, ok: 0, changed: 0, fail: 0, unverified: 0, stale: 0, steps: {}, last: null}, stale = {};
  (ledger || []).forEach(function (v) {   // file order is time order: the last line per step wins
    var k = v.capability + '/' + v.step;
    if (v.version === version) { s.steps[k] = v; s.last = v.at; } else stale[k] = 1;
  });
  (manifest.capabilities || []).forEach(function (c) { (c.steps || []).forEach(function (st) {
    var k = c.id + '/' + st.id, o = s.steps[k] && s.steps[k].outcome; s.total++;
    if (o === 'ok' || o === 'changed' || o === 'fail') s[o]++; else { s.unverified++; if (stale[k]) s.stale++; }
  }); });
  return s;
}
function records(packages) {   // [{manifest, footprints, ledger}] → 기능마다 기록 하나
  var out = [];
  (packages || []).forEach(function (p) {
    var m = p.manifest, s = summary(m, p.ledger), target = TARGET[(m.launch || {}).target] || '폰';
    (m.capabilities || []).forEach(function (c) {
      var r = {cap: c.title || c.id, path: target + '/' + m.name + '/' + (c.title || c.id), unverified: 0, total: 0, ok: 0, changed: 0, fail: 0, walks: (p.footprints || []).length, last: null, pkg: m.id};
      (c.steps || []).forEach(function (st) {
        var v = s.steps[c.id + '/' + st.id], o = v && v.outcome; r.total++;
        if (o === 'ok' || o === 'changed' || o === 'fail') { r[o]++; var d = String(v.at || '').slice(0, 10); if (!r.last || d > r.last) r.last = d; } else r.unverified++;
      });
      out.push({id: m.id + '/' + c.id, fields: r});
    });
  });
  return {records: out, schema: SCHEMA};
}
root.Verify = {TARGET, SCHEMA, summary, records};
})(globalThis);
