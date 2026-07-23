import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { containmentFeatureEnabled } from '../config.ts';

test('production freezes signup and costly integrations unless explicitly enabled', () => {
  assert.equal(containmentFeatureEnabled(true, undefined), false);
  assert.equal(containmentFeatureEnabled(true, 'false'), false);
  assert.equal(containmentFeatureEnabled(true, 'TRUE'), false);
  assert.equal(containmentFeatureEnabled(true, 'true'), true);
});

test('development remains usable but can exercise the freeze', () => {
  assert.equal(containmentFeatureEnabled(false, undefined), true);
  assert.equal(containmentFeatureEnabled(false, 'false'), false);
});

test('signup is public, CAPTCHA-gated, anti-enumerating, and never auto-confirms', async () => {
  const source = await readFile(new URL('./auth.ts', import.meta.url), 'utf8');
  assert.match(source, /auth\.signUp\(/);
  assert.match(source, /verifyCaptcha\(/);
  assert.match(source, /quota\.consume\(\{[\s\S]*capability: 'signup'/);
  assert.match(source, /GENERIC_SIGNUP_MESSAGE/);
  assert.match(source, /emailRedirectTo: `\$\{config\.publicBaseUrl\}\/auth\/verified`/);
  assert.doesNotMatch(source, /auth\.admin\.createUser|email_confirm\s*:\s*true/);
});

test('verified provisioning is idempotent and trial is last behind a fail-closed quota', async () => {
  const sql = await readFile(
    new URL('../../sql/011_identity_oauth_actions_scheduler.sql', import.meta.url),
    'utf8',
  );
  const profile = sql.indexOf('insert into public.danotch_user_profiles');
  const apps = sql.indexOf('insert into public.danotch_connected_apps');
  const trialQuota = sql.indexOf("'trial', p_trial_subject_hash");
  const trialUpdate = sql.indexOf('trial_started_at = coalesce');
  assert.ok(profile >= 0 && apps > profile && trialQuota > apps && trialUpdate > trialQuota);
  assert.match(sql, /email_confirmed_at into v_verified_at/);
  assert.match(sql, /requested_at <= v_verified_at/);
  assert.match(sql, /on conflict \(id\) do update/);
  assert.match(sql, /on conflict \(user_id, app_type\) do nothing/);
  assert.match(sql, /capability quota configuration unavailable/);
});
