import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import vm from 'node:vm';

// The web home and its record frames must use the shared tokens.css theme
// (system light/dark, html[data-theme] override) instead of a private palette.
const read = path => readFile(new URL(path, import.meta.url), 'utf8');
const stripComments = css => css.replace(/\/\*[\s\S]*?\*\//g, '');
const tokens = await read('../web/vendor/tokens.css');
const sharedTokens = new Set([...tokens.matchAll(/--([a-z0-9-]+)\s*:/g)].map(match => match[1]));
const documents = { 'index.html': '../index.html', 'record-frame.html': '../web/record-frame.html', 'timeline-frame.html': '../web/timeline-frame.html' };
const stylesheets = { 'home.css': '../web/home.css', 'install-guide.css': '../install-guide.css', 'record-frame.css': '../web/record-frame.css', 'timeline-frame.css': '../web/timeline-frame.css' };

test('viewer documents load the shared tokens first and leave the colour scheme to the system or host', async () => {
  for (const [name, path] of Object.entries(documents)) {
    const html = await read(path);
    const links = [...html.matchAll(/<link rel="stylesheet" href="([^"]+)">/g)].map(match => match[1]);
    assert.equal(links[0], '/web/vendor/tokens.css', `${name} loads tokens.css before its own styles`);
    assert.doesNotMatch(html, /data-theme=/, `${name} does not pin html[data-theme]`);
    assert.doesNotMatch(html, /name="color-scheme" content="dark"/, `${name} does not pin a dark colour scheme`);
  }
  assert.match(await read('../index.html'), /name="color-scheme" content="light dark"/);
  for (const name of ['record-frame.html', 'timeline-frame.html']) {
    assert.match(await read(documents[name]), /<script src="\/web\/frame-theme\.js"><\/script>/, `${name} applies a forwarded host theme before painting`);
  }
  // The timeline frame is generated; the generator must agree with the committed file.
  const generator = await read('../../scripts/sync-web-records.mjs');
  assert.doesNotMatch(generator, /data-theme=/);
  assert.match(generator, /<script src="\/web\/frame-theme\.js"><\/script><link rel="stylesheet" href="\/web\/vendor\/tokens\.css">/);
});

test('viewer stylesheets declare no palette of their own and only reference shared tokens', async () => {
  for (const [name, path] of Object.entries(stylesheets)) {
    const css = stripComments(await read(path));
    assert.doesNotMatch(css, /color-scheme\s*:/, `${name} inherits color-scheme from tokens.css`);
    assert.doesNotMatch(css, /--[a-z0-9-]+\s*:/, `${name} declares no custom properties`);
    const used = [...css.matchAll(/var\(--([a-z0-9-]+)/g)].map(match => match[1]);
    assert.ok(used.length > 0, `${name} uses the shared tokens`);
    for (const token of new Set(used)) assert.ok(sharedTokens.has(token), `${name} references --${token}, which tokens.css does not define`);
  }
});

test('viewer stylesheets carry no hard-coded colours except the evidence paper and the dialog scrim', async () => {
  for (const [name, path] of Object.entries(stylesheets)) {
    const lines = stripComments(await read(path)).split('\n').filter(line => !/\.evidence-column|::backdrop/.test(line));
    const colours = lines.join('\n').match(/#[0-9a-fA-F]{3,8}\b|\b(?:rgba?|hsla?)\(/g) ?? [];
    assert.deepEqual(colours, [], `${name} hard-codes colours: ${colours.join(', ')}`);
  }
});

test('the shared font may load on the web home', async () => {
  const vercel = JSON.parse(await read('../vercel.json'));
  const home = vercel.headers.find(rule => rule.source === '/').headers.find(header => header.key === 'Content-Security-Policy').value;
  assert.match(home, /(^|; )font-src 'self'(;|$)/, 'tokens.css @font-face needs font-src on /');
});

async function frameSourceFor(name, theme) {
  const { renderRecords } = await import('../web/record-views.js');
  const frames = [];
  const element = tag => ({ tagName: tag.toUpperCase(), attributes: {}, children: [], className: '',
    setAttribute(key, value) { this.attributes[key] = value; }, append(...nodes) { this.children.push(...nodes); if (tag === 'div') frames.push(...nodes); },
    replaceChildren() { this.children = []; }, querySelector() { return null; }, remove() {} });
  const container = element('div');
  globalThis.document = { documentElement: { dataset: theme === undefined ? {} : { theme } }, createElement: element, getElementById: () => container };
  globalThis.window = { addEventListener() {}, removeEventListener() {} };
  try {
    const controller = new AbortController();
    const pending = renderRecords(name, { data: {} }, { container, signal: controller.signal });
    controller.abort();
    await assert.rejects(pending, error => error.code === 'cancelled');
    assert.equal(frames.length, 1, 'exactly one frame is appended');
    assert.equal(frames[0].attributes.sandbox, 'allow-scripts', 'the sandbox contract is unchanged');
    return frames[0].src;
  } finally { delete globalThis.document; delete globalThis.window; }
}

test('record frames follow the system scheme unless the host document pins html[data-theme]', async () => {
  assert.match(await frameSourceFor('accounting'), /^\/web\/record-frame\.html#[a-f0-9]{32}$/);
  assert.match(await frameSourceFor('timeline', 'light'), /^\/web\/timeline-frame\.html\?theme=light#[a-f0-9]{32}$/);
  assert.match(await frameSourceFor('health', 'dark'), /^\/web\/record-frame\.html\?theme=dark#[a-f0-9]{32}$/);
  assert.match(await frameSourceFor('spatial', 'sepia'), /^\/web\/record-frame\.html#[a-f0-9]{32}$/, 'unknown values are not forwarded');
});

test('frame-theme.js applies only light or dark from the frame URL', async () => {
  const source = await read('../web/frame-theme.js');
  const run = search => {
    const documentElement = { dataset: {} };
    vm.runInContext(source, vm.createContext({ location: { search }, document: { documentElement }, URLSearchParams }), { filename: 'hub/web/frame-theme.js' });
    return documentElement.dataset.theme;
  };
  assert.equal(run(''), undefined);
  assert.equal(run('?theme=light'), 'light');
  assert.equal(run('?theme=dark'), 'dark');
  assert.equal(run('?theme=sepia'), undefined);
  assert.equal(run('?theme=dark%20onload'), undefined);
});
