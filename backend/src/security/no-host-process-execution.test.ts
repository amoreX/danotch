import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFile, readdir } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { hostedTools, executeHostedTool } from '../tools/local.ts';

const backendRoot = fileURLToPath(new URL('../../', import.meta.url));

async function sourceFiles(directory: string): Promise<string[]> {
  const entries = await readdir(directory, { withFileTypes: true });
  const nested = await Promise.all(entries.map(async (entry) => {
    const fullPath = path.join(directory, entry.name);
    if (entry.isDirectory()) return sourceFiles(fullPath);
    return /\.(?:ts|js|mjs|cjs)$/.test(entry.name) ? [fullPath] : [];
  }));
  return nested.flat();
}

test('hosted tool registry exposes no shell or process executor', () => {
  const names = hostedTools.map((tool) => tool.name);
  assert.equal(names.includes('bash_execute'), false);
  assert.equal(names.some((name) => /(?:shell|command|process|exec|spawn)/i.test(name)), false);
});

test('unknown hosted tools fail closed', async () => {
  await assert.rejects(
    executeHostedTool('bash_execute', { command: 'id' }),
    /not registered for hosted execution/,
  );
  await assert.rejects(
    executeHostedTool('dynamic_process_launcher', {}),
    /not registered for hosted execution/,
  );
});

test('backend application source has no child-process dependency', async () => {
  const files = await sourceFiles(path.join(backendRoot, 'src'));
  for (const file of files) {
    if (file.endsWith('no-host-process-execution.test.ts')) continue;
    const source = await readFile(file, 'utf8');
    assert.doesNotMatch(source, /(?:node:)?child_process/, file);
  }
});

test('production start command enables Node permissions without child process grant', async () => {
  const packageJson = JSON.parse(await readFile(path.join(backendRoot, 'package.json'), 'utf8'));
  assert.match(packageJson.scripts.start, /--permission/);
  assert.doesNotMatch(packageJson.scripts.start, /--allow-child-process/);
});
