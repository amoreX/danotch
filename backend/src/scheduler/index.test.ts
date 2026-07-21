import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { test } from 'node:test';

test('replicas claim schedules with skip-locked leases and fenced completion', async () => {
  const sql = await readFile(
    new URL('../../sql/011_identity_oauth_actions_scheduler.sql', import.meta.url),
    'utf8',
  );
  assert.match(sql, /for update skip locked limit p_limit/);
  assert.match(sql, /lease_owner = p_worker_id/);
  assert.match(sql, /lease_token = gen_random_uuid\(\)/);
  assert.match(sql, /task\.lease_token <> p_lease_token/);
  assert.match(sql, /task\.lease_expires_at <= now\(\)/);
  assert.match(sql, /danotch_renew_schedule_lease/);
  assert.match(sql, /run_state = 'poisoned'/);
  assert.match(sql, /'cancelled', 'poisoned'/);
  assert.match(sql, /run_state = 'retry_wait'/);
});

test('device-local schedules enqueue durable bound runs and never invoke hosted providers', async () => {
  const source = await readFile(new URL('./index.ts', import.meta.url), 'utf8');
  const localBranch = source.indexOf("if (task.execution_location === 'device_local')");
  const providerCall = source.indexOf('provider.complete');
  assert.ok(localBranch >= 0 && providerCall > localBranch);
  const branchSource = source.slice(localBranch, providerCall);
  assert.match(branchSource, /'queued_local'/);
  assert.match(branchSource, /return;/);
  assert.doesNotMatch(branchSource, /provider\.complete|executeComposioTool|host command execution/);

  const sql = await readFile(
    new URL('../../sql/011_identity_oauth_actions_scheduler.sql', import.meta.url),
    'utf8',
  );
  assert.match(sql, /execution_location in \('hosted', 'device_local'\)/);
  assert.match(sql, /foreign key \(bound_device_id, user_id\)/);
  assert.match(sql, /insert into public\.danotch_runs/);
  assert.match(sql, /'execution_location', 'device_local'/);
  assert.match(sql, /'schedule:' \|\| task\.id::text \|\| ':attempt:'/);
});

test('hosted scheduler source contains no local command execution path', async () => {
  const source = await readFile(new URL('./index.ts', import.meta.url), 'utf8');
  assert.doesNotMatch(source, /bash_execute|execFile|spawn\(/);
  assert.match(source, /danotch_renew_schedule_lease/);
});
