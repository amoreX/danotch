import { test } from 'node:test';
import assert from 'node:assert/strict';
import { validateScheduledPatch } from './scheduled-policy.ts';

test('scheduler PATCH accepts only documented editable fields', () => {
  const result = validateScheduledPatch({
    enabled: false,
    name: 'Updated',
    prompt: 'New prompt',
    cron: '0 9 * * *',
    interval_ms: 120_000,
    notify_user: true,
    target_app: 'gmail',
  });

  assert.equal(result.ok, true);
  if (result.ok) {
    assert.deepEqual(Object.keys(result.updates).sort(), [
      'cron',
      'enabled',
      'interval_ms',
      'name',
      'notify_user',
      'prompt',
      'target_app',
    ]);
  }
});

test('scheduler PATCH rejects protected and unknown columns', () => {
  for (const field of [
    'id',
    'user_id',
    'run_count',
    'last_result',
    'last_run_at',
    'next_run_at',
    'created_at',
    'updated_at',
    'task_type',
    'lease_owner',
  ]) {
    const result = validateScheduledPatch({ enabled: false, [field]: 'forged' });
    assert.equal(result.ok, false, `${field} must be rejected`);
  }
});

test('scheduler PATCH rejects empty and wrongly typed updates', () => {
  assert.equal(validateScheduledPatch({}).ok, false);
  assert.equal(validateScheduledPatch({ enabled: 'yes' }).ok, false);
  assert.equal(validateScheduledPatch({ interval_ms: 10 }).ok, false);
});
