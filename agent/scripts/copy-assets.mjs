import { cp, mkdir, readFile, writeFile } from 'node:fs/promises';
await cp(new URL('../index.html', import.meta.url), new URL('../dist/index.html', import.meta.url));
// The shared tokens as one standalone stylesheet for the Mac's own web pages (timeline, evidence): colors + tokens.
const colors = await readFile(new URL('../src/generated/theme-colors.css', import.meta.url), 'utf8');
const tokens = (await readFile(new URL('../src/tokens.css', import.meta.url), 'utf8')).replace(/^@import[^\n]*\n/m, '');
await writeFile(new URL('../dist/tokens.css', import.meta.url), colors + tokens);
for (const target of ['../../Ppomi/Sources/Ppomi/Web/Agent/', '../../Android/app/src/main/assets/agent/']) {
 const directory = new URL(target, import.meta.url);
 await mkdir(directory, { recursive: true });
 await cp(new URL('../dist/', import.meta.url), directory, { recursive: true });
}
// Mac pages live one directory above the bundle: point the font at Agent/fonts.
await writeFile(new URL('../../Ppomi/Sources/Ppomi/Web/tokens.css', import.meta.url),
  (colors + tokens).replaceAll('./fonts/', './Agent/fonts/'));
