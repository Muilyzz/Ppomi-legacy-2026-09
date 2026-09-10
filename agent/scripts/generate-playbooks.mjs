import { createHash } from 'node:crypto';
import { mkdir, rename, writeFile } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { readCatalog, validateManifest } from '../../hub/lib/catalog.js';

// A fixed build input: never the deployed hub copy, an environment URL, or a model-selected path.
export const catalogSource = fileURLToPath(new URL('../../Ppomi/Sources/Ppomi/Catalog/', import.meta.url));
export const generatedPath = fileURLToPath(new URL('../src/generated/playbooks.json', import.meta.url));

/** Keep only documented public procedure fields; unknown manifest fields and asset bytes stay out. */
export function publicCatalog(catalog) {
  const commonGuide = catalog.playbooks[0]?.commonGuide ?? '';
  const playbooks = catalog.playbooks.map(({ manifest, guide, commonGuide: common }) => {
    validateManifest(manifest);
    if (typeof guide !== 'string' || typeof common !== 'string' || common !== commonGuide) {
      throw new Error('Invalid catalog: inconsistent guide content');
    }
    return {
      id: manifest.id,
      name: manifest.name,
      aliases: [...manifest.aliases],
      version: manifest.version,
      launch: { search: manifest.launch.search, ...(manifest.launch.target ? { target: manifest.launch.target } : {}) },
      humanSteps: [...manifest.humanSteps],
      capabilities: manifest.capabilities.map(capability => ({
        id: capability.id,
        title: capability.title,
        description: capability.description,
        inputs: capability.inputs.map(input => ({ name: input.name, label: input.label, required: input.required })),
        steps: capability.steps.map(step => ({ id: step.id, title: step.title, kind: step.kind })),
      })),
      guide,
    };
  });
  const data = { schemaVersion: 1, source: 'Catalog', commonGuide, playbooks };
  return { ...data, sourceSha256: createHash('sha256').update(JSON.stringify(data)).digest('hex') };
}

export async function generatePlaybooks() {
  // readCatalog validates each manifest, names/aliases, paths and non-symlink package assets.
  const data = publicCatalog(await readCatalog(catalogSource));
  await mkdir(path.dirname(generatedPath), { recursive: true });
  const temporary = `${generatedPath}.tmp`;
  await writeFile(temporary, JSON.stringify(data, null, 2) + '\n', { mode: 0o644 });
  await rename(temporary, generatedPath);
  return data.playbooks.length;
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const count = await generatePlaybooks();
  console.log(`Bundled ${count} validated Catalog playbooks.`);
}
