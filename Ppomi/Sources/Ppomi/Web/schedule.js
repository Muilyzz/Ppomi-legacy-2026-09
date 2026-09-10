// Web/schedule.js — 약정 대조. 계약·약정이 정한 기대(매월 N일에 얼마)를 만들고 실제 분개와 맞춘다. 임대·대출 상환·구독·급여에 같은 함수.
// 기대일이 속한 달 안의 같은 경로 분개를 날짜순으로 한 번씩만 배정한다. 결과는 facts.js 형식의 파생 기록이라 시간축이 바로 그린다:
// 기대일 → 정산일 막대의 길이가 곧 연체 기간이다. 판정은 납부·부분납·미납·예정 넷뿐이고 '안 냈다'는 사실을 만들어내지 않는다 — 분개가 없다는 뜻이다.
//   rules:   [{id, path, day, amount, from, to, label}]     entries: [{at:'YYYY-MM-DD', path, amount}]
//   → [{id, fields:{label, path, due, settled, expected, actual, status, state, prov:'derived'}}]   status 코드 · state 한글 · prov 는 늘 derived(계산이지 관측이 아니다)
(function (root) {
'use strict';
var STATUS = {paid: '납부', partial: '부분납', unpaid: '미납', upcoming: '예정'};
function utc(s) { var m = /^(\d{4})-(\d{2})-(\d{2})/.exec(String(s)); return Date.UTC(+m[1], m[2] - 1, +m[3]); }
function ymd(ms) { return new Date(ms).toISOString().slice(0, 10); }
function under(p, prefix) { return p === prefix || String(p).indexOf(prefix + '/') === 0; }

// 매월 day 일, from~to 안. 그 달에 day 가 없으면 말일(31일 약정의 2월 = 28일).
function dues(rule) {
  var f = new Date(utc(rule.from)), a = utc(rule.from), b = utc(rule.to), out = [];
  for (var k = 0; k < 1200; k++) {
    var y = f.getUTCFullYear(), m = f.getUTCMonth() + k, last = new Date(Date.UTC(y, m + 1, 0)).getUTCDate(), d = Date.UTC(y, m, Math.min(rule.day, last));
    if (d > b) break;
    if (d >= a) out.push(d);
  }
  return out;
}
function reconcile(rules, entries, today) {
  var T = today == null ? Date.now() : utc(today), out = [];
  rules.forEach(function (rule) {
    var mine = entries.filter(function (e) { return under(e.path, rule.path); }).map(function (e) { return {at: utc(e.at), amount: +e.amount || 0, used: false}; }).sort(function (a, b) { return a.at - b.at; });
    dues(rule).forEach(function (due) {
      var d = new Date(due), m0 = Date.UTC(d.getUTCFullYear(), d.getUTCMonth(), 1), m1 = Date.UTC(d.getUTCFullYear(), d.getUTCMonth() + 1, 1), got = 0, last = null;
      mine.forEach(function (e) { if (e.used || e.at < m0 || e.at >= m1 || got >= rule.amount) return; e.used = true; got += e.amount; last = e.at; });
      var status = got >= rule.amount ? 'paid' : got > 0 ? 'partial' : due > T ? 'upcoming' : 'unpaid';
      out.push({id: rule.id + ':' + ymd(due), fields: {label: rule.label || rule.path, path: rule.path, due: ymd(due),
        settled: status === 'paid' ? ymd(last) : status === 'upcoming' ? null : ymd(T), expected: rule.amount, actual: got, status: status, state: STATUS[status], prov: 'derived'}});
    });
  });
  return out;
}
var SCHEMA = {fields: [{key: 'label', title: '약정', type: 'text'}, {key: 'path', title: '경로', type: 'path'}, {key: 'due', title: '기대일', type: 'time', until: 'settled'}, {key: 'settled', title: '정산일', type: 'time'},
  {key: 'expected', title: '기대', type: 'amount', unit: '원'}, {key: 'actual', title: '실제', type: 'amount', unit: '원'}, {key: 'state', title: '상태', type: 'text'}, {key: 'prov', title: '출처', type: 'provenance'}]};
root.Schedule = {STATUS, dues, reconcile, SCHEMA};
})(globalThis);
