import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { test } from 'node:test';

const migration = await readFile(
  new URL('../../sql/013_billing_launch_readiness.sql', import.meta.url),
  'utf8',
);

test('checkout reservation RPC serializes one active checkout per commercial key', () => {
  assert.match(migration, /danotch_checkout_records_one_active_idx[\s\S]*user_id, product_id, environment/);
  assert.match(migration, /pg_advisory_xact_lock/);
  assert.match(migration, /status in \('pending', 'active'\)/);
  assert.match(migration, /'checkout:' \|\| gen_random_uuid\(\)::text/);
});

test('payment RPC requires exact internal record and Dodo session attachment', () => {
  assert.match(migration, /id = p_checkout_record_id/);
  assert.match(migration, /dodo_session_id = p_dodo_session_id/);
  assert.match(migration, /expected_quantity = p_quantity/);
  assert.match(migration, /environment = p_environment/);
  assert.match(migration, /status = 'active'/);
});

test('payment and reversal delivery claims are atomic under concurrency', () => {
  const claims = migration.match(/on conflict do nothing/g) ?? [];
  assert.ok(claims.length >= 2);
  assert.match(migration, /danotch_payment_events_semantic_event_uidx/);
  assert.match(migration, /create function public\.danotch_record_payment_reversal/);
  assert.match(migration, /dodo_payment_id = p_payment_id/);
  assert.match(migration, /granted payment not found for reversal[\s\S]*errcode = '40001'/);
});

test('revocation preserves purchase history and only terminal policy events revoke', () => {
  assert.match(migration, /p_event_type = 'refund\.succeeded'/);
  assert.match(migration, /p_event_type in \('dispute\.accepted', 'dispute\.lost'\)/);
  assert.match(migration, /lifetime_revoked_at = now\(\)/);
  assert.doesNotMatch(
    migration,
    /set[\s\S]{0,120}lifetime_purchased_at = null/,
  );
});
