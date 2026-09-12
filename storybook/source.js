// Code 탭: html-vite 기본은 장식된 DOM, type:'code' 는 CSF args. 마운트/렌더 사용 예로 바꾼다.
const KIND = {
  '분개': {mount: 'Journal.mount'},
  '값 종류 뷰': {mount: 'Facts.mount'},
  '증거': {mount: 'Evidence.mount'},
  '시크릿': {mount: 'Secrets.mount'},
  '상태': {mount: 'Status.mount'},
  '절차': {mount: 'Playbook.mount'},
  '대화 셸': {jsx: 'Shell'},
  '작업대': {jsx: 'Workbench'},
};

export function usageSource(src, ctx = {}) {
  const docs = ctx.parameters?.docs?.source || {};
  const kind = KIND[ctx.title] || {};
  const mount = docs.mount || kind.mount;
  const jsx = docs.jsx || kind.jsx;
  const fn = String(ctx.unboundStoryFn || ctx.originalStoryFn || '');
  if (mount && /\.mount\s*\(/.test(fn)) return mountUsage(mount, ctx.args, ctx.argTypes);
  if (jsx) return jsxUsage(jsx, ctx.args, ctx.argTypes);
  if (/^\s*(async\s+)?(function|\()/.test(fn)) return fn;
  return src;
}

function mountUsage(mount, args, argTypes) {
  return `const el = document.createElement('div');\n${mount}(el, ${formatObject(args, argTypes)});`;
}

function jsxUsage(name, args, argTypes) {
  const props = [];
  for (const [key, value] of Object.entries(args || {})) {
    if (typeof value === 'function') continue;
    if (!isLite(value) || argTypes?.[key]?.table?.disable) { props.push(`  ${key}={${key}}`); continue; }
    if (typeof value === 'boolean') { if (value) props.push(`  ${key}`); continue; }
    if (typeof value === 'string') { props.push(`  ${key}=${JSON.stringify(value)}`); continue; }
    props.push(`  ${key}={${JSON.stringify(value)}}`);
  }
  const inner = props.length ? `\n${props.join('\n')}\n` : '';
  return `const el = document.createElement('div');\ncreateRoot(el).render(<${name}${inner}/>);`;
}

function formatObject(args, argTypes) {
  const lines = [];
  for (const [key, value] of Object.entries(args || {})) {
    if (typeof value === 'function') continue;
    if (!isLite(value) || argTypes?.[key]?.table?.disable) { lines.push(`  ${key},`); continue; }
    lines.push(`  ${key}: ${JSON.stringify(value)},`);
  }
  return `{\n${lines.join('\n')}\n}`;
}

function isLite(value) {
  if (value == null) return true;
  const t = typeof value;
  if (t === 'string' || t === 'number' || t === 'boolean') return true;
  if (Array.isArray(value)) return value.length <= 8 && value.every(isLite);
  if (t !== 'object' || value.$$typeof) return false;
  const keys = Object.keys(value);
  return keys.length <= 6 && keys.every((k) => isLite(value[k]));
}
