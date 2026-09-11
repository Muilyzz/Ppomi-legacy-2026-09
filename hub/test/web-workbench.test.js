import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { AGENT_ENDPOINT } from '../web/config.js';

// The web home is the shared workbench bundle (agent/src/web-main.tsx) mounted by home.js. These checks pin the page,
// policy and bundle contract that the browser needs to reach the same agent server the Mac and Android apps use.
const read = path => readFile(new URL(path, import.meta.url), 'utf8');

test('the home page mounts the shared workbench after the shared tokens and before the glue', async () => {
  const html = await read('../index.html');
  const links = [...html.matchAll(/<link rel="stylesheet" href="([^"]+)">/g)].map(match => match[1]);
  assert.deepEqual(links, ['/web/vendor/tokens.css', '/web/workbench/app.css', '/install-guide.css', '/web/home.css']);
  const scripts = [...html.matchAll(/<script[^>]*src="([^"]+)"[^>]*><\/script>/g)].map(match => match[1]);
  assert.deepEqual(scripts, ['/install-guide.js', '/web/workbench/app.js', '/web/home.js']);
  assert.match(html, /<script src="\/web\/workbench\/app\.js" defer>/, 'the bundle defines the global home.js mounts');
  assert.match(html, /<main id="root"/);
  assert.doesNotMatch(html, /<script>(?!<\/script>)/, 'no inline script: the page runs under script-src self');
  assert.doesNotMatch(html, /style="/, 'no inline style attributes under style-src self');
  assert.doesNotMatch(html, /id="sign-in"|id="main-content"|data-record-view=/, 'the vanilla shell is gone; the workbench renders sign-in and records');
});

test('the content security policy admits exactly the two servers the browser talks to', async () => {
  const vercel = JSON.parse(await read('../vercel.json'));
  const home = vercel.headers.find(rule => rule.source === '/').headers.find(header => header.key === 'Content-Security-Policy').value;
  const directives = Object.fromEntries(home.split(';').map(part => part.trim()).filter(Boolean).map(part => { const [name, ...values] = part.split(/\s+/); return [name, values]; }));
  assert.deepEqual(directives['script-src'], ["'self'"]);
  assert.deepEqual(directives['style-src'], ["'self'"]);
  assert.deepEqual(directives['connect-src'], ["'self'", 'https://nafutfqfbbmknzmyspus.supabase.co', 'wss://nafutfqfbbmknzmyspus.supabase.co', AGENT_ENDPOINT]);
  assert.deepEqual(directives['frame-src'], ["'self'"], 'record frames stay same-origin sandboxed documents');
  assert.match(AGENT_ENDPOINT, /^https:\/\/[a-z0-9.-]+$/, 'a bare https origin; the token travels in a header, never in the URL');
});

test('the agent endpoint is the one the Mac and Android apps default to', async () => {
  const swift = await read('../../Ppomi/Sources/Ppomi/Shared/SupabaseAuth.swift');
  const kotlin = await read('../../Android/app/src/main/java/com/ppomi/androidbridge/VoiceBridgePolicy.java');
  assert.match(swift, new RegExp(`agentEndpoint = "${AGENT_ENDPOINT.replaceAll('.', '\\.')}"`));
  assert.match(kotlin, new RegExp(`DEFAULT_AGENT_ENDPOINT = "${AGENT_ENDPOINT.replaceAll('.', '\\.')}"`));
});

test('the service worker caches the workbench bundle as a public file and nothing authenticated', async () => {
  const worker = await read('../service-worker.js');
  const paths = [...worker.matchAll(/'(\/[^']*)'/g)].map(match => match[1]);
  for (const path of ['/', '/web/workbench/app.js', '/web/workbench/app.css', '/web/home.js', '/web/vendor/tokens.css',
    '/web/transcript-session.js', '/web/transcript-realtime.js', '/web/transcript-protocol.js']) assert.ok(paths.includes(path), `${path} is cached`);
  assert.equal(paths.includes('/web/transcript-crypto.js'), false);
  assert.equal(paths.some(path => path.startsWith('/api/') || path.includes('supabase')), false);
  assert.match(worker, /request\.headers\.has\('Authorization'\)/, 'authenticated requests bypass the cache');
  assert.match(worker, /ppomi-public-home-20260911-12/, 'the cache version moved with the new static files');
});

test('the committed bundle exposes the mount function, points at the shared font and carries no credential', async () => {
  const js = await read('../web/workbench/app.js');
  const css = await read('../web/workbench/app.css');
  assert.match(js, /^var PpomiWebWorkbench=/);
  assert.match(js, /mountWebWorkbench/);
  assert.match(js, /"web"/, 'the browser bootstrap platform');
  assert.match(js, /generateId:\(\)=>crypto\.randomUUID\(\)/, 'transcript turn ids are UUIDs');
  // SDK code names its environment variables; what must be absent is any key value in the known formats.
  assert.doesNotMatch(js, /sb_(?:publishable|secret)_[A-Za-z0-9_-]{16,}|\bsk-(?:proj-)?[A-Za-z0-9_-]{16,}\b|\bvck_[A-Za-z0-9_-]{16,}\b/);
  assert.doesNotMatch(js, /https:\/\/[a-z0-9]{20}\.supabase\.co/, 'the bundle does not name the auth server; the glue owns that configuration');
  assert.match(css, /url\(\.\.\/vendor\/Agent\/fonts\/PretendardVariable\.woff2\)/);
  assert.doesNotMatch(css, /url\(\.\/fonts\//);
});
