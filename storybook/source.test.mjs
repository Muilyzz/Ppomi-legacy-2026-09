import test from 'node:test';
import assert from 'node:assert/strict';
import {usageSource} from './source.js';

const csf = "export const Building = { args: { depth: 2 } };";
const mountFn = {toString: () => '(args) => { const el = document.createElement("div"); X.mount(el, args); return el; }'};

test('Facts.mount args become a mount snippet, not CSF', () => {
  const out = usageSource(csf, {
    title: '값 종류 뷰',
    args: {depth: 2, root: '', selected: null, records: [{id: 1, fields: {}}], schema: {fields: []}, onSelect() {}},
    argTypes: {records: {table: {disable: true}}, schema: {table: {disable: true}}},
    originalStoryFn: mountFn,
  });
  assert.match(out, /Facts\.mount\(el,/);
  assert.match(out, /depth: 2/);
  assert.match(out, /records,/);
  assert.doesNotMatch(out, /export const/);
  assert.doesNotMatch(out, /onSelect/);
});

test('story parameters.docs.source.mount wins over the title map', () => {
  const out = usageSource(csf, {
    title: '값 종류 뷰',
    parameters: {docs: {source: {mount: 'Journal.mount'}}},
    args: {unit: 'month'},
    originalStoryFn: mountFn,
  });
  assert.match(out, /Journal\.mount\(el,/);
  assert.match(out, /unit: "month"/);
});

test('Shell stories become createRoot + JSX, not CSF args', () => {
  const out = usageSource("export const First = { args: { platform: 'macos' } };", {
    title: '대화 셸',
    args: {platform: 'macos', conversation: {$$typeof: Symbol.for('react.element')}, onClose() {}},
    argTypes: {conversation: {table: {disable: true}}},
    originalStoryFn: (args) => args,
  });
  assert.match(out, /createRoot\(el\)\.render\(<Shell/);
  assert.match(out, /platform="macos"/);
  assert.match(out, /conversation=\{conversation\}/);
  assert.doesNotMatch(out, /export const/);
});

test('custom render without mount keeps the function source', () => {
  const render = () => page();
  const out = usageSource(csf, {title: '개발자', originalStoryFn: render});
  assert.match(out, /page\(/);
  assert.doesNotMatch(out, /export const/);
});
