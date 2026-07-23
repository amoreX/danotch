import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { readFile } from 'node:fs/promises';
import { test } from 'node:test';
import { normalizeActionParameters } from './parameters.ts';
import {
  ACTION_REGISTRY_VERSION,
  getActionDeliveryContract,
} from './registry.ts';

test('canonical action parameters have a stable order-independent digest', () => {
  const first = normalizeActionParameters({ z: 1, nested: { b: 2, a: 1 } });
  const second = normalizeActionParameters({ nested: { a: 1, b: 2 }, z: 1 });
  const digest = (value: Record<string, unknown>) => createHash('sha256')
    .update(JSON.stringify(value))
    .digest('hex');
  assert.deepEqual(first, second);
  assert.equal(digest(first), digest(second));
  assert.throws(() => normalizeActionParameters({ constructor: 'pollution' }));
});

test('approval revalidates immutable registry, account, device, expiry, and delivery contract', async () => {
  const source = await readFile(new URL('./pending.ts', import.meta.url), 'utf8');
  for (const binding of [
    'registry_version',
    'parameters_hash',
    'account_id',
    'device_id',
    'delivery_semantics',
    'retry_semantics',
    'reconciliation_semantics',
  ]) {
    assert.match(source, new RegExp(binding));
  }
  assert.match(source, /normalizedHash !== candidate\.parameters_hash/);
  assert.match(source, /\.eq\('status', 'executing'\)/);
  assert.match(source, /terminal_decision: 'ambiguous_provider_outcome'/);
  assert.match(source, /reconciliation_required: true/);
  assert.match(source, /danotch_expire_pending_actions/);

  assert.equal(ACTION_REGISTRY_VERSION, '1');
  const mutation = getActionDeliveryContract('GMAIL_SEND_EMAIL');
  assert.deepEqual(mutation, {
    policy: 'approval',
    provider: 'composio',
    idempotency: 'none',
    retry: 'never_after_dispatch',
    reconciliation: 'manual_required',
  });
});

test('database prevents mutation of the claimed action contract', async () => {
  const sql = await readFile(
    new URL('../../sql/011_identity_oauth_actions_scheduler.sql', import.meta.url),
    'utf8',
  );
  assert.match(sql, /pending action contract is immutable/);
  assert.match(sql, /new\.user_id, new\.action_type, new\.payload, new\.registry_version/);
  assert.match(sql, /new\.account_id, new\.device_id/);
  assert.match(sql, /new\.idempotency_key, new\.expires_at/);
  assert.match(sql, /status = 'expired'[\s\S]*terminal_decision = 'expired'/);
});
