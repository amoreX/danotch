import { createHash } from 'node:crypto';
import { mkdirSync } from 'node:fs';
import { dirname } from 'node:path';
import { DatabaseSync } from 'node:sqlite';
import { migrations, type Migration } from './migrations.js';

export type SqliteDatabase = DatabaseSync;

function checksum(migration: Migration): string {
  return createHash('sha256')
    .update(`${migration.version}\0${migration.name}\0${migration.sql}`)
    .digest('hex');
}

export function migrate(db: SqliteDatabase, plan: readonly Migration[] = migrations): void {
  db.exec(`
    CREATE TABLE IF NOT EXISTS schema_migrations (
      version INTEGER PRIMARY KEY,
      name TEXT NOT NULL,
      checksum TEXT NOT NULL,
      applied_at TEXT NOT NULL
    )
  `);

  const applied = new Map(
    (db.prepare('SELECT version, name, checksum FROM schema_migrations ORDER BY version').all() as
      { version: number; name: string; checksum: string }[])
      .map((row) => [row.version, row]),
  );

  for (const migration of plan) {
    const expected = checksum(migration);
    const existing = applied.get(migration.version);
    if (existing) {
      if (existing.name !== migration.name || existing.checksum !== expected) {
        throw new Error(`Migration ${migration.version} checksum mismatch`);
      }
      continue;
    }

    db.exec('BEGIN IMMEDIATE');
    try {
      db.exec(migration.sql);
      db.prepare(
        'INSERT INTO schema_migrations(version, name, checksum, applied_at) VALUES (?, ?, ?, ?)',
      ).run(migration.version, migration.name, expected, new Date().toISOString());
      db.exec('COMMIT');
    } catch (error) {
      db.exec('ROLLBACK');
      throw error;
    }
  }
}

export function openDatabase(path: string): SqliteDatabase {
  if (path !== ':memory:') mkdirSync(dirname(path), { recursive: true, mode: 0o700 });
  const db = new DatabaseSync(path);
  db.exec('PRAGMA foreign_keys = ON');
  db.exec('PRAGMA busy_timeout = 5000');
  if (path !== ':memory:') db.exec('PRAGMA journal_mode = WAL');
  db.exec('PRAGMA synchronous = NORMAL');
  migrate(db);
  return db;
}

export function verifyDatabase(db: SqliteDatabase): void {
  const foreignKeys = db.prepare('PRAGMA foreign_keys').get() as { foreign_keys: number };
  if (foreignKeys.foreign_keys !== 1) throw new Error('SQLite foreign keys are disabled');
  migrate(db);
  const integrity = db.prepare('PRAGMA quick_check').get() as { quick_check: string };
  if (integrity.quick_check !== 'ok') throw new Error(`SQLite integrity check failed: ${integrity.quick_check}`);
}
