import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';

test('ordinary authenticated routes do not import an unrestricted secret client', async () => {
  const ordinaryRoutes = [
    'routes/auth.ts',
    'routes/apps.ts',
    'routes/billing.ts',
    'routes/notifications.ts',
    'routes/provider.ts',
    'routes/runs.ts',
    'routes/scheduled.ts',
    'routes/tasks.ts',
  ];
  for (const relative of ordinaryRoutes) {
    const source = await readFile(new URL(relative, new URL('../', import.meta.url)), 'utf8');
    assert.doesNotMatch(source, /SUPABASE_(?:SERVICE|SECRET)_KEY/);
    assert.doesNotMatch(source, /from ['"].*lib\/supabase\.js['"].*supabase\b/);
  }

  const singleton = await readFile(new URL('lib/supabase.ts', new URL('../', import.meta.url)), 'utf8');
  assert.doesNotMatch(singleton, /SERVICE_KEY|SECRET_KEY|service-role|bypasses RLS/i);
});

test('admin client requires an explicit operation and has no general export', async () => {
  const source = await readFile(new URL('lib/admin-db.ts', new URL('../', import.meta.url)), 'utf8');
  for (const operation of [
    'bootstrap', 'webhook', 'scheduler', 'fencing', 'reconciliation', 'provider', 'runner',
  ]) {
    assert.match(source, new RegExp(`['"]${operation}['"]`));
  }
  assert.doesNotMatch(source, /export const (?:supabase|adminDb)\b/);
  assert.match(source, /getAdminDb\(operation: AdminOperation\)/);
});

test('database operation roles have explicit grants and no authenticated transition writes', async () => {
  const sql = await readFile(new URL('../../sql/005_rls_and_constraints.sql', import.meta.url), 'utf8');
  for (const role of [
    'danotch_bootstrap',
    'danotch_webhook',
    'danotch_scheduler',
    'danotch_fencing',
    'danotch_reconciler',
    'danotch_provider',
  ]) {
    assert.match(sql, new RegExp(`\\b${role}\\b`));
  }
  assert.doesNotMatch(
    sql,
    /grant\s+(?:insert|update|all)[^;]*danotch_pending_actions\s+to\s+authenticated/is,
  );
  assert.doesNotMatch(
    sql,
    /grant\s+(?:insert|update|all)[^;]*danotch_connection_requests\s+to\s+authenticated/is,
  );
  assert.match(sql, /grant update \(read\) on public\.danotch_notifications to authenticated/);
  assert.match(sql, /create policy[\s\S]*using \([^;]+\)[\s\S]*with check \(/i);
});

test('durable protocol grants only operation roles authoritative writes', async () => {
  const sql = await readFile(new URL('../../sql/006_devices_runs_events.sql', import.meta.url), 'utf8');
  for (const table of [
    'danotch_runs',
    'danotch_run_events',
    'danotch_event_acknowledgements',
    'danotch_local_action_requests',
    'danotch_action_decisions',
    'danotch_execution_grants',
    'danotch_run_cancellations',
    'danotch_terminal_results',
  ]) {
    assert.match(sql, new RegExp(`create table public\\.${table}`));
    assert.match(sql, new RegExp(`create index[^;]+on public\\.${table}\\(user_id`, 'is'));
  }
  assert.doesNotMatch(
    sql,
    /grant\s+(?:insert|update|delete|all)[^;]*danotch_(?:runs|run_events|event_acknowledgements|local_action_requests|action_decisions|execution_grants|terminal_results)[^;]*to\s+authenticated/is,
  );
  assert.match(sql, /grant execute on function public\.danotch_transition_run[\s\S]*to danotch_runner/);
  for (const reducer of [
    'danotch_acknowledge_event',
    'danotch_decide_local_action',
    'danotch_mint_execution_grant',
    'danotch_consume_execution_grant',
    'danotch_cancel_run',
    'danotch_record_action_result',
  ]) {
    assert.match(sql, new RegExp(`create function public\\.${reducer}`));
    assert.match(sql, new RegExp(`revoke all on function public\\.${reducer}`));
  }
  assert.match(sql, /consumed_at is null/);
  assert.match(sql, /unique \(run_id, run_sequence\)/);
  assert.match(sql, /unique \(device_id, device_sequence\)/);

  const fingerprint = await readFile(
    new URL('../../scripts/schema-contract.mjs', import.meta.url),
    'utf8',
  );
  assert.match(fingerprint, /'role', rolname \|\| ':bypassrls='/);
  assert.match(fingerprint, /'danotch_runner'/);
});

test('device enrollment and gateway tickets are fencing-only atomic operations', async () => {
  const sql = await readFile(new URL('../../sql/007_device_gateway.sql', import.meta.url), 'utf8');
  for (const table of ['danotch_device_challenges', 'danotch_gateway_tickets']) {
    assert.match(sql, new RegExp(`create table public\\.${table}`));
    assert.doesNotMatch(
      sql,
      new RegExp(`grant\\s+(?:insert|update|delete|all)[^;]*${table}[^;]*to\\s+authenticated`, 'is'),
    );
  }
  for (const reducer of [
    'danotch_enroll_device',
    'danotch_create_gateway_ticket',
    'danotch_consume_gateway_ticket',
    'danotch_revoke_device',
    'danotch_fence_user_devices',
    'danotch_assert_device_fence',
    'danotch_fenced_acknowledge_event',
    'danotch_fenced_decide_local_action',
    'danotch_fenced_record_action_result',
    'danotch_fenced_cancel_run',
    'danotch_fence_connection_logout',
  ]) {
    assert.match(sql, new RegExp(`create function public\\.${reducer}`));
    assert.match(
      sql,
      new RegExp(`grant execute on function public\\.${reducer}[\\s\\S]*?to danotch_fencing`),
    );
  }
  assert.match(sql, /select \* into claimed[\s\S]*for update/);
  assert.match(sql, /current_fence = current_fence \+ 1/);
  assert.match(sql, /consumed_at is not null/);
});

test('replay, quotas, snapshots, and grants remain operation-scoped and fail closed', async () => {
  const sql = await readFile(new URL('../../sql/008_replay_recovery.sql', import.meta.url), 'utf8');
  for (const table of [
    'danotch_protocol_quota_config',
    'danotch_reconnect_attempts',
  ]) {
    assert.match(sql, new RegExp(`create table public\\.${table}`));
    assert.doesNotMatch(
      sql,
      new RegExp(`grant\\s+(?:insert|update|delete|all)[^;]*${table}[^;]*to\\s+authenticated`, 'is'),
    );
  }
  for (const reducer of [
    'danotch_prepare_device_replay',
    'danotch_fenced_claim_approval_and_mint_grant',
    'danotch_fenced_consume_execution_grant',
    'danotch_expire_waiting_device_runs',
  ]) {
    assert.match(sql, new RegExp(`create function public\\.${reducer}`));
    assert.match(sql, new RegExp(`revoke all on function public\\.${reducer}`));
  }
  assert.match(sql, /replay_cursor = p_device_sequence/);
  assert.match(sql, /first_sequence > device\.replay_cursor \+ 1/);
  assert.match(sql, /protocol quota configuration unavailable/);
  assert.match(sql, /run_row\.state <> 'waiting_for_device'/);
  assert.match(sql, /grant_row\.normalized_parameters = p_normalized_parameters/);
  assert.match(sql, /grant_row\.consumed_at is null and grant_row\.revoked_at is null/);
  assert.match(sql, /initiating device affinity is immutable/);
  assert.match(sql, /device_work_cancelled_before_execution/);
  assert.match(
    sql,
    /revoke execute on function public\.danotch_mint_execution_grant[\s\S]*from danotch_runner, danotch_fencing/,
  );
  assert.doesNotMatch(
    sql,
    /grant\s+(?:insert|update|delete|all)[^;]*danotch_(?:reconnect_attempts|execution_grants|run_events)[^;]*to\s+authenticated/is,
  );
});

test('identity, OAuth, action, and scheduler hardening remains operation scoped', async () => {
  const sql = await readFile(
    new URL('../../sql/011_identity_oauth_actions_scheduler.sql', import.meta.url),
    'utf8',
  );
  for (const table of [
    'danotch_capability_quota_config',
    'danotch_capability_quota_events',
    'danotch_verified_provisioning',
    'danotch_signup_enrollments',
    'danotch_oauth_link_attempts',
  ]) {
    assert.match(sql, new RegExp(`create table public\\.${table}`));
    assert.match(sql, new RegExp(`alter table public\\.${table} force row level security`));
    assert.doesNotMatch(
      sql,
      new RegExp(`grant\\s+(?:insert|update|delete|all)[^;]*${table}[^;]*to\\s+authenticated`, 'is'),
    );
  }
  assert.match(sql, /to danotch_bootstrap/);
  assert.match(sql, /to danotch_scheduler/);
  assert.match(
    sql,
    /grant execute on function public\.danotch_claim_due_schedules[\s\S]*public\.danotch_renew_schedule_lease[\s\S]*to danotch_scheduler/,
  );
  assert.match(sql, /to danotch_bootstrap, danotch_scheduler, danotch_fencing/);
  assert.doesNotMatch(
    sql,
    /grant execute on function public\.danotch_(?:consume_capability_quota|provision_verified_user|claim_due_schedules|finish_schedule_attempt)[^;]*to authenticated/is,
  );
});

test('result finalization elevates only the validated reducer and provisioning qualifies pgcrypto', async () => {
  const sql = await readFile(
    new URL('../../sql/015_provisioning_result_privileges.sql', import.meta.url),
    'utf8',
  );

  assert.match(
    sql,
    /alter function public\.danotch_record_action_result\([\s\S]*?\)\s+security definer;/i,
  );
  assert.doesNotMatch(
    sql,
    /alter function public\.danotch_transition_run\([\s\S]*?\)\s+security definer;/i,
  );
  assert.match(
    sql,
    /revoke execute on function public\.danotch_transition_run\([\s\S]*?\)\s+from danotch_fencing;/i,
  );
  assert.doesNotMatch(
    sql,
    /grant execute on function public\.danotch_transition_run\([\s\S]*?\)\s+to danotch_fencing;/i,
  );

  assert.match(
    sql,
    /create or replace function public\.danotch_provision_verified_user[\s\S]*security definer set search_path = ''/i,
  );
  assert.equal(sql.match(/public\.digest\(/g)?.length, 2);
  assert.doesNotMatch(sql.replaceAll('public.digest(', ''), /\bdigest\(/);
});
