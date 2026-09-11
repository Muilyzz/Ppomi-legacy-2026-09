import { cp, mkdir, readFile } from 'node:fs/promises';
// hub has no build step: the web workbench bundle is committed next to the browser-only modules it is mounted from.
const source = new URL('../dist-web/', import.meta.url), target = new URL('../../hub/web/workbench/', import.meta.url);
const js = await readFile(new URL('app.js', source), 'utf8');
if (!js.includes('mountWebWorkbench')) throw new Error('dist-web/app.js does not export mountWebWorkbench');
await mkdir(target, { recursive: true });
for (const name of ['app.js', 'app.css']) await cp(new URL(name, source), new URL(name, target));
