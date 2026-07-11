import 'dotenv/config';
import { readFile, readdir } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import path from 'node:path';
import { Client } from 'pg';

// Ordered, recorded migration runner. Discovers backend/sql/*.sql files, applies
// any not yet recorded in danotch_schema_migrations, each inside its own
// transaction, in filename order. Safe to run repeatedly (idempotent).

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
const sqlDir = fileURLToPath(new URL('../sql/', import.meta.url));

const files = (await readdir(sqlDir))
  .filter((f) => f.endsWith('.sql'))
  .sort((a, b) => a.localeCompare(b, undefined, { numeric: true }));

const client = new Client({
  connectionString,
  ssl: connectionString.includes('localhost') ? false : { rejectUnauthorized: false },
});

try {
  await client.connect();
  await client.query(`
    create table if not exists public.danotch_schema_migrations (
      version text primary key,
      applied_at timestamptz not null default now()
    );
  `);

  const { rows } = await client.query('select version from public.danotch_schema_migrations');
  const applied = new Set(rows.map((r) => r.version));

  const pending = files.filter((f) => !applied.has(f));

  if (verifyOnly) {
    if (pending.length > 0) {
      console.error(`Schema verification failed. Pending migrations: ${pending.join(', ')}`);
      process.exit(1);
    }
    console.log(`Schema verified. ${files.length} migration(s) applied.`);
    process.exit(0);
  }

  if (pending.length === 0) {
    console.log('No pending migrations.');
  }

  for (const file of pending) {
    const sql = await readFile(path.join(sqlDir, file), 'utf8');
    console.log(`Applying ${file}...`);
    try {
      await client.query('begin');
      await client.query(sql);
      await client.query('insert into public.danotch_schema_migrations (version) values ($1)', [file]);
      await client.query('commit');
      console.log(`  ✓ ${file}`);
    } catch (err) {
      await client.query('rollback');
      console.error(`  ✗ ${file} failed and was rolled back:`, err.message);
      throw err;
    }
  }

  console.log('Migrations complete.');
} finally {
  await client.end();
}
