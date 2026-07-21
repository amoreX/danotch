import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { readdir, readFile } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import path from 'node:path';
import { Client } from 'pg';
import { databaseUrl, withClient } from './test-db.ts';
import { schemaFingerprint } from '../../scripts/schema-contract.mjs';

const sqlDir = fileURLToPath(new URL('../../sql/', import.meta.url));

test('migration ledger contains ordered immutable checksums and catalog fingerprint', {
  skip: !databaseUrl,
}, async () => {
  const files = (await readdir(sqlDir))
    .filter((file) => file.endsWith('.sql'))
    .sort((a, b) => a.localeCompare(b, undefined, { numeric: true }));
  const expected = new Map<string, string>();
  for (const file of files) {
    const sql = await readFile(path.join(sqlDir, file), 'utf8');
    expected.set(file, createHash('sha256').update(sql).digest('hex'));
  }

  await withClient(async (client) => {
    const { rows } = await client.query(
      `select version, checksum, schema_fingerprint
       from public.danotch_schema_migrations order by version`,
    );
    assert.deepEqual(rows.map((row) => row.version), files);
    for (const row of rows) assert.equal(row.checksum, expected.get(row.version));
    const recorded = [...rows].reverse().find((row) => row.schema_fingerprint)?.schema_fingerprint;
    assert.match(recorded, /^[a-f0-9]{64}$/);
    assert.equal(await schemaFingerprint(client), recorded);
  });
});

test('migration advisory lock excludes concurrent writers', {
  skip: !databaseUrl,
}, async () => {
  const first = new Client({ connectionString: databaseUrl });
  const second = new Client({ connectionString: databaseUrl });
  await first.connect();
  await second.connect();
  try {
    await first.query(`select pg_advisory_lock(hashtext('danotch_schema_migrations'))`);
    const attempt = await second.query(
      `select pg_try_advisory_lock(hashtext('danotch_schema_migrations')) as acquired`,
    );
    assert.equal(attempt.rows[0].acquired, false);
  } finally {
    await first.query(`select pg_advisory_unlock(hashtext('danotch_schema_migrations'))`);
    await first.end();
    await second.end();
  }
});

test('catalog fingerprint detects unknown drift without repairing it', {
  skip: !databaseUrl,
}, async () => {
  await withClient(async (client) => {
    const ledger = await client.query(
      `select schema_fingerprint from public.danotch_schema_migrations
       where schema_fingerprint is not null`,
    );
    const recorded = ledger.rows[0].schema_fingerprint;
    await client.query('begin');
    await client.query('create table public.danotch_unknown_drift(id integer)');
    const drifted = await schemaFingerprint(client);
    assert.notEqual(drifted, recorded);
    await client.query('rollback');
    const after = await schemaFingerprint(client);
    assert.equal(after, recorded);
  });
});
