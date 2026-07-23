import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { test } from 'node:test';
import { CaptchaVerifier } from './captcha.ts';
import {
  QuotaExceededError,
  QuotaUnavailableError,
  SupabaseQuotaStore,
  hashQuotaSubject,
} from './quota-store.ts';
import { isEmailVerified } from './identity-state.ts';
import {
  ACTION_REGISTRY_VERSION,
  getActionDeliveryContract,
} from '../actions/registry.ts';
import { normalizeActionParameters } from '../actions/parameters.ts';

test('CAPTCHA verification fails closed and enforces the configured hostname', async () => {
  const accepted = new CaptchaVerifier(
    { provider: 'turnstile', secret: 'secret', expectedHostname: 'signup.example.com' },
    async () => new Response(JSON.stringify({ success: true, hostname: 'signup.example.com' })),
  );
  assert.equal(await accepted.verify('proof', '203.0.113.8'), true);

  const wrongHost = new CaptchaVerifier(
    { provider: 'turnstile', secret: 'secret', expectedHostname: 'signup.example.com' },
    async () => new Response(JSON.stringify({ success: true, hostname: 'evil.example' })),
  );
  assert.equal(await wrongHost.verify('proof'), false);

  const outage = new CaptchaVerifier(
    { provider: 'hcaptcha', secret: 'secret' },
    async () => { throw new Error('outage'); },
  );
  assert.equal(await outage.verify('proof'), false);
});

test('distributed quota adapter distinguishes outage from a denied capability', async () => {
  const unavailable = new SupabaseQuotaStore({
    async rpc() { return { data: null, error: { message: 'db unavailable' } }; },
  } as never);
  await assert.rejects(() => unavailable.consume({
    capability: 'oauth',
    subject: 'owner-1',
  }), QuotaUnavailableError);

  const denied = new SupabaseQuotaStore({
    async rpc() { return { data: { allowed: false, retry_after_seconds: 42 }, error: null }; },
  } as never);
  await assert.rejects(() => denied.consume({
    capability: 'action',
    subject: 'owner-1',
  }), (error: unknown) => error instanceof QuotaExceededError && error.retryAfterSeconds === 42);
  assert.match(hashQuotaSubject('Owner-1'), /^[0-9a-f]{64}$/);
});

test('every costly production capability uses the distributed quota store', async () => {
  const files = [
    ['../routes/auth.ts', "'signup'"],
    ['../agent/runner.ts', "'provider'"],
    ['../routes/devices.ts', "'enrollment'"],
    ['../routes/apps.ts', "'oauth'"],
    ['../tools/scheduled.ts', "'scheduler'"],
    ['../actions/pending.ts', "'action'"],
    ['../protocol/replay.ts', "'replay'"],
    ['../protocol/durable-run-store.ts', "'storage'"],
  ] as const;
  for (const [relative, capability] of files) {
    const source = await readFile(new URL(relative, import.meta.url), 'utf8');
    assert.match(source, /SupabaseQuotaStore|QuotaStore/);
    assert.ok(source.includes(`capability: ${capability}`), `${relative} must quota ${capability}`);
  }
});

test('only verified Supabase users qualify for provisioning', () => {
  assert.equal(isEmailVerified({ email_confirmed_at: null, confirmed_at: null }), false);
  assert.equal(isEmailVerified({
    email_confirmed_at: '2026-07-21T00:00:00Z',
    confirmed_at: null,
  }), true);
});

test('signup source uses public verification and never admin auto-confirm', async () => {
  const source = await readFile(new URL('../routes/auth.ts', import.meta.url), 'utf8');
  assert.match(source, /auth\.signUp\(/);
  assert.match(source, /verifyCaptcha\(/);
  assert.match(source, /check_email/);
  assert.doesNotMatch(source, /auth\.admin\.createUser|email_confirm\s*:\s*true/);
  assert.doesNotMatch(source, /adminError\?\.message|loginError\?\.message/);
});

test('migration repairs partial provisioning and makes trial creation idempotent', async () => {
  const sql = await readFile(
    new URL('../../sql/011_identity_oauth_actions_scheduler.sql', import.meta.url),
    'utf8',
  );
  assert.match(sql, /danotch_verified_provisioning/);
  assert.match(sql, /email_confirmed_at into v_verified_at/);
  assert.match(sql, /requested_at <= v_verified_at/);
  assert.match(sql, /on conflict \(user_id, app_type\) do nothing/);
  assert.match(sql, /if not provision\.trial_ready/);
  assert.match(sql, /danotch_consume_capability_quota/);
  assert.match(sql, /capability quota configuration unavailable/);
});

test('OAuth state, actions, and scheduler are durable and fail closed', async () => {
  const sql = await readFile(
    new URL('../../sql/011_identity_oauth_actions_scheduler.sql', import.meta.url),
    'utf8',
  );
  assert.match(sql, /danotch_oauth_link_attempts_one_active_idx/);
  assert.match(sql, /where status = 'pending' and consumed_at is null/);
  assert.match(sql, /danotch_pending_action_contract_immutable/);
  assert.match(sql, /for update skip locked/);
  assert.match(sql, /danotch_finish_schedule_attempt/);
  assert.match(sql, /execution_location in \('hosted', 'device_local'\)/);
  assert.match(sql, /'source', 'scheduled_task'/);
});

test('normalized immutable action parameters and delivery semantics are exact', () => {
  assert.deepEqual(
    normalizeActionParameters({ z: 1, nested: { b: true, a: 'x' }, a: [2, 1] }),
    { a: [2, 1], nested: { a: 'x', b: true }, z: 1 },
  );
  assert.throws(() => normalizeActionParameters({ bad: Number.NaN }));
  const mutation = getActionDeliveryContract('GMAIL_SEND_EMAIL');
  assert.equal(ACTION_REGISTRY_VERSION, '1');
  assert.equal(mutation?.retry, 'never_after_dispatch');
  assert.equal(mutation?.reconciliation, 'manual_required');
});
