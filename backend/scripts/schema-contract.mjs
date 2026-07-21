import { createHash } from 'node:crypto';

export const ledgerTable = 'danotch_schema_migrations';

const legacyColumns = {
  danotch_user_profiles: [
    'id', 'email', 'full_name', 'created_at', 'trial_started_at', 'trial_ends_at',
    'lifetime_purchased_at', 'billing_status', 'dodo_customer_id', 'dodo_payment_id',
  ],
  danotch_connected_apps: [
    'id', 'user_id', 'app_type', 'active', 'composio_conn_id', 'connected_at',
    'disconnected_at', 'created_at',
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
  danotch_checkout_records: [
    'id', 'user_id', 'dodo_session_id', 'product_id', 'expected_amount',
    'expected_currency', 'expected_quantity', 'environment', 'status',
    'created_at', 'expires_at', 'consumed_at',
  ],
  danotch_payment_events: [
    'id', 'delivery_id', 'payment_id', 'claimed_user_id', 'profile_id',
    'event_type', 'amount', 'currency', 'product_id', 'outcome', 'error', 'created_at',
  ],
  danotch_connection_requests: [
    'id', 'user_id', 'session_id', 'app_type', 'display_name', 'reason', 'status',
    'created_at', 'expires_at', 'resolved_at',
  ],
  danotch_connection_attempts: [
    'id', 'user_id', 'app_type', 'toolkit_slug', 'state_nonce',
    'composio_account_id', 'status', 'created_at', 'expires_at', 'activated_at',
  ],
  danotch_pending_actions: [
    'id', 'user_id', 'session_id', 'action_type', 'summary', 'payload', 'status',
    'idempotency_key', 'result', 'error', 'created_at', 'expires_at', 'decided_at',
    'executed_at',
  ],
};

const knownLegacyVariants = {
  danotch_user_profiles: ['avatar_url', 'plan'],
  danotch_scheduled_tasks: ['updated_at'],
};

export async function assertKnownLegacyShape(client) {
  const { rows } = await client.query(`
    select table_name, column_name
    from information_schema.columns
    where table_schema = 'public' and table_name like 'danotch_%'
    order by table_name, ordinal_position
  `);
  const actual = new Map();
  for (const row of rows) {
    if (row.table_name === ledgerTable) continue;
    const columns = actual.get(row.table_name) ?? [];
    columns.push(row.column_name);
    actual.set(row.table_name, columns);
  }

  const actualTables = [...actual.keys()].sort();
  const baseTables = [
    'danotch_user_profiles',
    'danotch_connected_apps',
    'danotch_provider_configs',
    'danotch_threads',
    'danotch_messages',
    'danotch_scheduled_tasks',
    'danotch_notifications',
  ].sort();
  const fullTables = Object.keys(legacyColumns).sort();
  const isBase = JSON.stringify(actualTables) === JSON.stringify(baseTables);
  const isFull = JSON.stringify(actualTables) === JSON.stringify(fullTables);
  if (!isBase && !isFull) {
    throw new Error(
      `Baseline refused: table set is not a known legacy schema.\n`
      + `Expected base: ${baseTables.join(', ')}\n`
      + `Expected U1: ${fullTables.join(', ')}\nActual: ${actualTables.join(', ')}`,
    );
  }

  const expectedColumns = isBase
    ? {
        ...Object.fromEntries(baseTables.map((table) => [table, legacyColumns[table]])),
        danotch_user_profiles: ['id', 'email', 'full_name', 'created_at'],
      }
    : legacyColumns;
  for (const [table, required] of Object.entries(expectedColumns)) {
    const columns = actual.get(table) ?? [];
    const allowed = new Set([...required, ...(knownLegacyVariants[table] ?? [])]);
    const missing = required.filter((column) => !columns.includes(column));
    const unknown = columns.filter((column) => !allowed.has(column));
    if (missing.length || unknown.length) {
      throw new Error(
        `Baseline refused: ${table} does not match a known legacy fingerprint `
        + `(missing: ${missing.join(', ') || 'none'}; unknown: ${unknown.join(', ') || 'none'}).`,
      );
    }
  }

  const { rows: policies } = await client.query(`
    select policyname from pg_policies
    where schemaname = 'public' and tablename like 'danotch_%'
  `);
  if (policies.length > 0) {
    throw new Error('Baseline refused: legacy database has unrecognized RLS policies.');
  }
  return isFull
    ? ['001_billing_entitlements.sql', '002_payment_checkout_and_events.sql',
        '003_connection_requests.sql', '004_pending_actions.sql']
    : [];
}

export async function schemaFingerprint(client) {
  const { rows } = await client.query(`
    with objects as (
      select 'column'::text as kind,
        c.table_name || '.' || c.ordinal_position || '.' || c.column_name || ':'
          || c.data_type || ':' || c.is_nullable || ':' || coalesce(c.column_default, '') as value
      from information_schema.columns c
      where c.table_schema = 'public'
        and c.table_name like 'danotch_%'
        and c.table_name <> '${ledgerTable}'
      union all
      select 'constraint', conrelid::regclass::text || '.' || conname || ':'
        || pg_get_constraintdef(oid, true)
      from pg_constraint
      where connamespace = 'public'::regnamespace
        and conrelid::regclass::text like 'danotch_%'
      union all
      select 'index', indexname || ':' || indexdef
      from pg_indexes
      where schemaname = 'public'
        and tablename like 'danotch_%'
        and tablename <> '${ledgerTable}'
      union all
      select 'policy', tablename || '.' || policyname || ':' || cmd || ':'
        || coalesce(qual, '') || ':' || coalesce(with_check, '')
      from pg_policies
      where schemaname = 'public' and tablename like 'danotch_%'
      union all
      select 'function', p.proname || ':' || pg_get_function_identity_arguments(p.oid)
        || ':' || pg_get_functiondef(p.oid)
      from pg_proc p
      where p.pronamespace = 'public'::regnamespace and p.proname like 'danotch_%'
      union all
      select 'trigger', event_object_table || '.' || trigger_name || ':'
        || action_timing || ':' || event_manipulation || ':' || action_statement
      from information_schema.triggers
      where trigger_schema = 'public' and event_object_table like 'danotch_%'
      union all
      select 'role', rolname || ':bypassrls=' || rolbypassrls::text
      from pg_roles
      where rolname in (
        'danotch_bootstrap', 'danotch_webhook', 'danotch_scheduler',
        'danotch_fencing', 'danotch_reconciler', 'danotch_provider',
        'danotch_runner'
      )
      union all
      select 'table_grant', table_name || ':' || grantee || ':' || privilege_type
      from information_schema.role_table_grants
      where table_schema = 'public' and table_name like 'danotch_%'
        and grantee in (
          'anon', 'authenticated', 'danotch_bootstrap', 'danotch_webhook',
          'danotch_scheduler', 'danotch_fencing', 'danotch_reconciler',
          'danotch_provider', 'danotch_runner'
        )
      union all
      select 'column_grant', table_name || '.' || column_name || ':' || grantee || ':' || privilege_type
      from information_schema.column_privileges
      where table_schema = 'public' and table_name like 'danotch_%'
        and grantee in (
          'anon', 'authenticated', 'danotch_bootstrap', 'danotch_webhook',
          'danotch_scheduler', 'danotch_fencing', 'danotch_reconciler',
          'danotch_provider', 'danotch_runner'
        )
    )
    select kind, value from objects order by kind, value
  `);
  return createHash('sha256').update(JSON.stringify(rows)).digest('hex');
}
