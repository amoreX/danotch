import assert from 'node:assert/strict';
import { test } from 'node:test';
import { readdir, readFile } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import { EXPECTED_MIGRATION_COUNT } from './migration-contract.ts';

test('runtime readiness migration count matches immutable SQL files', async () => {
  const sqlDirectory = fileURLToPath(new URL('../../sql/', import.meta.url));
  const files = (await readdir(sqlDirectory)).filter((file) => file.endsWith('.sql'));
  assert.equal(EXPECTED_MIGRATION_COUNT, files.length);
});

test('Render routes only after the dependency-aware readiness probe passes', async () => {
  const renderConfig = await readFile(
    fileURLToPath(new URL('../../render.yaml', import.meta.url)),
    'utf8',
  );
  assert.match(renderConfig, /^\s*healthCheckPath:\s*\/health\/ready\s*$/m);
});
