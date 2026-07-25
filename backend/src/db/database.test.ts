import assert from 'node:assert/strict';
import { test } from 'node:test';
import { openDatabase, migrate, verifyDatabase } from './database.ts';
import { Repositories } from './repositories.ts';

test('SQLite enables foreign keys and applies checksummed migrations', () => {
  const db = openDatabase(':memory:');
  try {
    verifyDatabase(db);
    const foreignKeys = db.prepare('PRAGMA foreign_keys').get() as { foreign_keys: number };
    assert.equal(foreignKeys.foreign_keys, 1);
    db.prepare('UPDATE schema_migrations SET checksum=? WHERE version=1').run('tampered');
    assert.throws(() => migrate(db), /checksum mismatch/);
  } finally {
    db.close();
  }
});

test('provider preferences persist identifiers but never secret material', () => {
  const db = openDatabase(':memory:');
  try {
    const repos = new Repositories(db);
    const provider = repos.saveProvider({
      provider: 'deepseek',
      modelId: 'deepseek-chat',
      keychainAccount: 'provider-deepseek',
      active: true,
    });
    assert.equal(repos.getProvider()?.id, provider.id);
    const columns = db.prepare('PRAGMA table_info(provider_preferences)').all() as { name: string }[];
    assert.equal(columns.some(({ name }) => /secret|api_key|token/i.test(name)), false);
  } finally {
    db.close();
  }
});

test('schedule claims are transactional and exclusive', () => {
  const db = openDatabase(':memory:');
  try {
    const repos = new Repositories(db);
    const schedule = repos.saveSchedule({
      name: 'Local check',
      prompt: 'check',
      taskType: 'poll',
      intervalMs: 60_000,
    });
    db.prepare('UPDATE schedules SET next_run_at=? WHERE id=?')
      .run(new Date(Date.now() - 1_000).toISOString(), schedule.id);
    assert.equal(repos.claimDueSchedules(10).length, 1);
    assert.equal(repos.claimDueSchedules(10).length, 0);
  } finally {
    db.close();
  }
});

test('local identity and integration metadata persist without credentials', () => {
  const db = openDatabase(':memory:');
  try {
    const repos = new Repositories(db);
    const first = repos.getOrCreateComposioUserId();
    assert.equal(repos.getOrCreateComposioUserId(), first);
    assert.match(first, /^local_[0-9a-f-]{36}$/);
    repos.saveIntegrationConfig('gmail', 'gmail', 'auth-config-1');
    assert.equal(repos.getIntegrationConfig('gmail')?.auth_config_id, 'auth-config-1');
    const serialized = JSON.stringify([
      ...db.prepare('SELECT * FROM local_identity').all(),
      ...db.prepare('SELECT * FROM integration_config').all(),
    ]);
    assert.doesNotMatch(serialized, /api.?key|credential|secret/i);
  } finally {
    db.close();
  }
});

test('pending actions preserve immutable hashes and accept one terminal result', () => {
  const db = openDatabase(':memory:');
  try {
    const repos = new Repositories(db);
    const action = repos.createPendingAction(null, 'shell.execute', 'Run tests', { command: 'npm test' }, {
      sessionId: 'session',
      origin: 'local',
      parametersHash: 'a'.repeat(64),
      actionHash: 'b'.repeat(64),
      capabilities: {},
    });
    assert.equal(action.parameters_hash, 'a'.repeat(64));
    assert.equal(repos.resolvePendingAction(action.id, 'approved', { source: 'test' }), true);
    const claimed = repos.claimPendingAction(action.id)!;
    assert.equal(repos.claimPendingAction(action.id), undefined);
    assert.equal(repos.finishPendingAction(
      action.id, claimed.execution_request_id!, 'completed', { stdout: 'ok' },
    ), true);
    assert.equal(repos.finishPendingAction(
      action.id, claimed.execution_request_id!, 'completed', { stdout: 'again' },
    ), false);
  } finally {
    db.close();
  }
});
