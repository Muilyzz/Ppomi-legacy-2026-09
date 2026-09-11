import {readFile, writeFile, mkdir, copyFile} from 'node:fs/promises';
import {fileURLToPath} from 'node:url';
import path from 'node:path';
import {createHash} from 'node:crypto';
const repo = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const source = path.join(repo, 'Ppomi/Sources/Ppomi/Web');
const dest = path.join(repo, 'hub/web/vendor');
await mkdir(dest, {recursive: true});
const hashes = {};
const legacy = JSON.parse(await readFile(path.join(repo, 'Ppomi/Sources/Ppomi/AccountingData/legacy-rules.json'), 'utf8'));
const rules = await readFile(path.join(repo, 'Ppomi/Sources/Ppomi/Ledger/Rules.swift'), 'utf8');
const normalize = rules.match(/leadingDigits = re\(#"(.*?)"#\), maskedNumber = re\(#"(.*?)"#\)/);
if (!normalize) throw new Error('Canonical legacy label normalization changed');
await writeFile(path.join(dest, 'ledger-display.js'), `// Generated display vocabulary and source-label normalization only. No accounting rules.\nexport default ${JSON.stringify({titles: legacy.titles, defaultLens: legacy.defaultLensName, leadingDigits: normalize[1], maskedNumber: normalize[2]})};\n`);
await mkdir(path.join(dest,'Agent/fonts'), {recursive:true});
for (const name of ['PretendardVariable.woff2','LICENSE-Pretendard.txt']) {
  await copyFile(path.join(source,'Agent/fonts',name), path.join(dest,'Agent/fonts',name));
}
for (const name of ['journal.js', 'playbook.js', 'tokens.css', 'theme.css']) {
  const bytes = await readFile(path.join(source, name));
  await writeFile(path.join(dest, name), bytes);
  hashes[name] = createHash('sha256').update(bytes).digest('hex');
}
const template = await readFile(path.join(source, 'timeline.html'), 'utf8');
const css = template.match(/<style>([\s\S]*?)<\/style>/)?.[1];
const js = template.match(/<script>([\s\S]*?)<\/script>/)?.[1];
const body = template.match(/<body>([\s\S]*?)<script>/)?.[1];
if (!css || !js || !body) throw new Error('Canonical timeline template changed');
await writeFile(path.join(dest, 'timeline.css'), css.replace('/*THEME*/', ''));
await writeFile(path.join(dest, 'timeline.js'), js);
hashes['timeline.html'] = createHash('sha256').update(template).digest('hex');
await writeFile(path.join(repo, 'hub/web/timeline-frame.html'), `<!doctype html>
<html lang="ko"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<meta name="referrer" content="no-referrer">
<meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self' data:; font-src 'self'; connect-src 'none'; frame-src 'none'; object-src 'none'; base-uri 'none'; form-action 'none'">
<title>뽀미 타임라인</title><script src="/web/frame-theme.js"></script><link rel="stylesheet" href="/web/vendor/tokens.css"><link rel="stylesheet" href="/web/vendor/theme.css"><link rel="stylesheet" href="/web/vendor/timeline.css"><link rel="stylesheet" href="/web/timeline-frame.css">
<script src="/web/vendor/timeline.js" defer></script><script src="/web/timeline-frame.js" defer></script>
</head><body><p id="source-note" class="meta" hidden></p>${body}<section id="source-transactions" hidden></section></body></html>\n`);
await writeFile(path.join(dest, 'sources.json'), JSON.stringify({source: 'Ppomi/Sources/Ppomi/Web', sha256: hashes}, null, 2) + '\n');
console.log('Synced canonical record renderers (no catalog or release changes).');
