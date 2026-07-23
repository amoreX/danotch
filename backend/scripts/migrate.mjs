import 'dotenv/config';
import { readFile, readdir } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import path from 'node:path';
import { createHash } from 'node:crypto';
import { Client } from 'pg';
import { assertKnownLegacyShape, ledgerTable, schemaFingerprint } from './schema-contract.mjs';

// Ordered, checksummed migration runner. Migration mode serializes writers with
// an advisory lock. Verify mode is a read-only transaction and never creates or
// repairs metadata. --baseline recognizes only the exact pre-U2 schema family.

const connectionString =
  process.env.DATABASE_URL ||
  process.env.POSTGRES_URL ||
  process.env.SUPABASE_DB_URL;

if (!connectionString) {
  console.error(
    'Missing DATABASE_URL, POSTGRES_URL, or SUPABASE_DB_URL. Add the Supabase Postgres connection string and rerun this script.',
  );
  process.exit(1);
}

if (!connectionString.startsWith('postgresql://') && !connectionString.startsWith('postgres://')) {
  console.error(
    'Invalid database URL. Supabase project URLs like https://<ref>.supabase.co are API URLs, not Postgres connection strings. Use a URL that starts with postgresql:// or postgres://.',
  );
  process.exit(1);
}

const verifyOnly = process.argv.includes('--verify');
const baseline = process.argv.includes('--baseline');
const fingerprintOnly = process.argv.includes('--fingerprint');
const sqlDir = fileURLToPath(new URL('../sql/', import.meta.url));

const files = (await readdir(sqlDir))
  .filter((f) => f.endsWith('.sql'))
  .sort((a, b) => a.localeCompare(b, undefined, { numeric: true }));
const migrations = await Promise.all(files.map(async (file) => {
  const sql = await readFile(path.join(sqlDir, file), 'utf8');
  return {
    file,
    sql,
    checksum: createHash('sha256').update(sql).digest('hex'),
  };
}));
const databaseUrl = new URL(connectionString);
const isLocalDatabase = ['localhost', '127.0.0.1', '::1'].includes(databaseUrl.hostname);
const ca = process.env.DATABASE_SSL_CA
  ?? (process.env.DATABASE_SSL_CA_FILE
    ? await readFile(process.env.DATABASE_SSL_CA_FILE, 'utf8')
    : undefined);

const client = new Client({
  connectionString,
  ssl: isLocalDatabase ? false : { rejectUnauthorized: true, ...(ca ? { ca } : {}) },
});

await main();

async function main() {
try {
  await client.connect();
  if (fingerprintOnly) {
    await client.query('begin read only');
    try {
      const fingerprint = await schemaFingerprint(client);
      await client.query('commit');
      console.log(`Schema fingerprint: ${fingerprint}`);
      return;
    } catch (error) {
      await client.query('rollback');
      throw error;
    }
  }
  if (verifyOnly) {
    await client.query('begin read only');
    try {
      const exists = await client.query(
        `select to_regclass('public.${ledgerTable}') is not null as exists`,
      );
      if (!exists.rows[0].exists) {
        throw new Error('Schema verification failed: migration ledger is missing.');
      }
      const { rows } = await client.query(
        `select version, checksum, schema_fingerprint from public.${ledgerTable} order by version`,
      );
      verifyLedger(rows, migrations);
      const recorded = [...rows].reverse().find((row) => row.schema_fingerprint)?.schema_fingerprint;
      if (!recorded) {
        throw new Error('Schema verification failed: no catalog fingerprint is recorded.');
      }
      const actual = await schemaFingerprint(client);
      if (actual !== recorded) {
        throw new Error(
          `Schema verification failed: catalog drift detected (recorded ${recorded}, actual ${actual}).`,
        );
      }
      await client.query('commit');
      console.log(`Schema verified read-only. ${migrations.length} migration(s), fingerprint ${actual}.`);
      return;
    } catch (error) {
      await client.query('rollback');
      throw error;
    }
  }

  await client.query(`select pg_advisory_lock(hashtext('danotch_schema_migrations'))`);
  try {
    await client.query(`
      create table if not exists public.${ledgerTable} (
        version text primary key,
        checksum text not null,
        applied_at timestamptz not null default now(),
        schema_fingerprint text
      )
    `);
    await client.query(
      `alter table public.${ledgerTable} add column if not exists checksum text`,
    );
    await client.query(
      `alter table public.${ledgerTable} add column if not exists schema_fingerprint text`,
    );

    const { rows } = await client.query(
      `select version, checksum, schema_fingerprint from public.${ledgerTable} order by version`,
    );

    if (baseline) {
      const recognizedVersions = await assertKnownLegacyShape(client);
      const recognized = new Set(recognizedVersions);
      const legacy = migrations.filter(({ file }) => recognized.has(file));
      const legacyNames = new Set(legacy.map(({ file }) => file));
      const unknownRows = rows.filter(({ version }) => !legacyNames.has(version));
      if (unknownRows.length > 0) {
        throw new Error(
          `Baseline refused: ledger contains unknown versions: ${unknownRows.map((row) => row.version).join(', ')}`,
        );
      }
      await client.query('begin');
      try {
        for (const migration of legacy) {
          await client.query(
            `insert into public.${ledgerTable}(version, checksum) values ($1, $2)
             on conflict (version) do update set checksum = excluded.checksum`,
            [migration.file, migration.checksum],
          );
        }
        await client.query(
          `alter table public.${ledgerTable} alter column checksum set not null`,
        );
        await client.query('commit');
        console.log(
          legacy.length > 0
            ? `Baselined known legacy schema at ${legacy.at(-1)?.file}.`
            : 'Recognized base-only manual schema; no delta migrations were marked applied.',
        );
      } catch (error) {
        await client.query('rollback');
        throw error;
      }
    } else {
      verifyAppliedChecksums(rows, migrations);
    }

    const refreshed = await client.query(`select version from public.${ledgerTable}`);
    const applied = new Set(refreshed.rows.map((row) => row.version));
    const pending = migrations.filter(({ file }) => !applied.has(file));
    if (pending.length === 0) console.log('No pending migrations.');

    for (const migration of pending) {
      console.log(`Applying ${migration.file}...`);
      await client.query('begin');
      try {
        await client.query(migration.sql);
        await client.query(
          `insert into public.${ledgerTable}(version, checksum) values ($1, $2)`,
          [migration.file, migration.checksum],
        );
        await client.query('commit');
        console.log(`  ✓ ${migration.file}`);
      } catch (error) {
        await client.query('rollback');
        console.error(`  ✗ ${migration.file} failed and was rolled back:`, error.message);
        throw error;
      }
    }

    const fingerprint = await schemaFingerprint(client);
    const finalVersion = migrations.at(-1)?.file;
    if (finalVersion) {
      await client.query(
        `update public.${ledgerTable}
         set schema_fingerprint = null
         where schema_fingerprint is not null and version <> $1`,
        [finalVersion],
      );
      await client.query(
        `update public.${ledgerTable}
         set schema_fingerprint = $2
         where version = $1 and schema_fingerprint is distinct from $2`,
        [finalVersion, fingerprint],
      );
    }
    console.log(`Migrations complete. Catalog fingerprint ${fingerprint}.`);
  } finally {
    await client.query(`select pg_advisory_unlock(hashtext('danotch_schema_migrations'))`);
  }
} finally {
  await client.end();
}
}

function verifyAppliedChecksums(rows, knownMigrations) {
  const known = new Map(knownMigrations.map((migration) => [migration.file, migration.checksum]));
  for (const row of rows) {
    const checksum = known.get(row.version);
    if (!checksum) throw new Error(`Unknown applied migration: ${row.version}`);
    if (!row.checksum) {
      throw new Error(
        `Migration ${row.version} predates checksums. Use --baseline only after restoring an empty ledger.`,
      );
    }
    if (checksum !== row.checksum) {
      throw new Error(`Applied migration checksum changed: ${row.version}`);
    }
  }
}

function verifyLedger(rows, knownMigrations) {
  verifyAppliedChecksums(rows, knownMigrations);
  const applied = new Set(rows.map((row) => row.version));
  const pending = knownMigrations.filter(({ file }) => !applied.has(file)).map(({ file }) => file);
  if (pending.length > 0) {
    throw new Error(`Schema verification failed. Pending migrations: ${pending.join(', ')}`);
  }
}
