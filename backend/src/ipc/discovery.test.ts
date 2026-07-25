import assert from 'node:assert/strict';
import { mkdtempSync, readFileSync, statSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { test } from 'node:test';
import { writeDiscoveryFile } from './discovery.ts';

test('discovery file has exact public fields and mode 0600', () => {
  const path = join(mkdtempSync(join(tmpdir(), 'perch-discovery-')), 'runtime', 'daemon.json');
  const record = { port: 49152, pid: 123, protocolVersion: 1, instanceId: 'instance' };
  writeDiscoveryFile(path, record);
  assert.deepEqual(JSON.parse(readFileSync(path, 'utf8')), record);
  assert.equal(statSync(path).mode & 0o777, 0o600);
});
