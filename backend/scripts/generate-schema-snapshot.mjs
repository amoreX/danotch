import { readFile, readdir, writeFile } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import path from 'node:path';

const backendDir = fileURLToPath(new URL('../', import.meta.url));
const sqlDir = path.join(backendDir, 'sql');
const output = path.join(backendDir, 'schema.sql');
const files = (await readdir(sqlDir))
  .filter((file) => file.endsWith('.sql'))
  .sort((a, b) => a.localeCompare(b, undefined, { numeric: true }));

const sections = await Promise.all(files.map(async (file) => {
  const sql = await readFile(path.join(sqlDir, file), 'utf8');
  return `-- BEGIN ${file}\n${sql.trimEnd()}\n-- END ${file}`;
}));
const snapshot = [
  '-- GENERATED FILE. Run `npm run db:snapshot` after changing ordered migrations.',
  '-- Ordered migrations are authoritative; this self-contained snapshot is derived from them.',
  ...sections,
  '',
].join('\n');

await writeFile(output, snapshot, 'utf8');
console.log(`Generated schema.sql from ${files.length} ordered migrations.`);
