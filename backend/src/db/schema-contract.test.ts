import { test } from 'node:test';
import assert from 'node:assert/strict';
import { assertKnownLegacyShape } from '../../scripts/schema-contract.mjs';

const baseColumns: Record<string, string[]> = {
  danotch_user_profiles: ['id', 'email', 'full_name', 'created_at'],
  danotch_connected_apps: [
    'id', 'user_id', 'app_type', 'active', 'composio_conn_id',
    'connected_at', 'disconnected_at', 'created_at',
  ],
  danotch_provider_configs: [
    'id', 'user_id', 'provider', 'api_key_encrypted', 'model_id', 'is_active',
    'verified_at', 'created_at', 'updated_at',
  ],
  danotch_threads: ['id', 'user_id', 'title', 'created_at', 'updated_at'],
  danotch_messages: ['id', 'thread_id', 'user_id', 'role', 'content', 'metadata', 'created_at'],
  danotch_scheduled_tasks: [
    'id', 'user_id', 'name', 'prompt', 'task_type', 'cron', 'interval_ms',
    'target_app', 'notify_user', 'enabled', 'next_run_at', 'last_run_at',
    'run_count', 'last_result', 'created_at',
  ],
  danotch_notifications: [
    'id', 'user_id', 'source', 'source_id', 'title', 'body', 'read', 'created_at',
  ],
};

function fakeClient(columns = baseColumns) {
  return {
    async query(sql: string) {
      if (sql.includes('information_schema.columns')) {
        return {
          rows: Object.entries(columns).flatMap(([table_name, names]) =>
            names.map((column_name) => ({ table_name, column_name }))),
        };
      }
      if (sql.includes('pg_policies')) return { rows: [] };
      throw new Error(`Unexpected query: ${sql}`);
    },
  };
}

test('safe baseline recognizes the exact manual base schema without marking deltas', async () => {
  const versions = await assertKnownLegacyShape(fakeClient());
  assert.deepEqual(versions, []);
});

test('safe baseline refuses unknown tables and columns', async () => {
  await assert.rejects(
    assertKnownLegacyShape(fakeClient({ ...baseColumns, danotch_shadow: ['id'] })),
    /table set is not a known legacy schema/,
  );
  await assert.rejects(
    assertKnownLegacyShape(fakeClient({
      ...baseColumns,
      danotch_threads: [...baseColumns.danotch_threads, 'attacker_column'],
    })),
    /unknown: attacker_column/,
  );
});
