// storybook/gov-fixture.js — docs/gov-sites.md(부처 → 기관 → 사이트 트리)를 값 종류 기록으로. 문서가 원본이고 여기는 파서뿐이다.
// 분야/부처/기관 = path, 사이트 수 = amount(1) 라서 트리맵이 분야·부처별 사이트 수가 된다. 우선순위·로그인·대상은 text, 주소·플레이북 id 는 ref.
const F = (key, title, type, extra) => ({key, title, type, ...extra});
export const govSchema = {fields: [F('site', '사이트', 'text'), F('path', '분야/부처/기관', 'path'), F('task', '할 일', 'text'), F('login', '로그인', 'text'), F('target', '대상', 'text'),
  F('priority', '우선순위', 'text'), F('pkg', '플레이북', 'ref'), F('url', '주소', 'ref'), F('count', '사이트 수', 'amount')]};
const LINK = /^\[(.+?)\]\((.+?)\)$/;
export function parseGovSites(md) {
  let section = '', dept = '', org = '', n = 0; const records = [];
  for (const line of md.split('\n')) {
    if (line.startsWith('## ')) { section = line.slice(3).trim(); continue; }
    const m = /^( *)- (.*)$/.exec(line); if (!m || section.startsWith('우선순위') || section === '출처') continue;
    const indent = m[1].length, body = m[2].trim();
    if (indent === 0) dept = (LINK.exec(body) || [, body])[1];
    else if (indent === 2) org = body;
    else if (indent === 4) {
      const [head, task, login, target, priority, ...rest] = body.split(' · '), link = LINK.exec(head);
      const pkg = rest.map((r) => /^패키지 (\S+)$/.exec(r)).find(Boolean);
      records.push({id: 'gov' + (++n), fields: {site: link ? link[1] : head, url: link ? link[2] : '', path: [section, dept, org].join('/'), task, login,
        target: target === '[W]' ? 'Windows' : 'Mac', priority, pkg: pkg ? pkg[1] : '', count: 1}});
    }
  }
  return records;
}
