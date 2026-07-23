import assert from 'node:assert/strict';
import { test } from 'node:test';
import { databaseUrl, withClient } from './test-db.ts';

const USER_ID = '61000000-0000-4000-8000-000000000001';
const EMAIL = 'fresh-launch-user@example.com';
const TRIAL_HASH = 'f'.repeat(64);
const APPS = ['gmail', 'googlecalendar', 'googledocs', 'github'];

test('fresh verified-user provisioning atomically creates a valid trial contract', {
  skip: !databaseUrl,
}, async () => {
  await withClient(async (client) => {
    await client.query('begin');
    try {
      await client.query(
        `insert into auth.users(id, email, email_confirmed_at, raw_user_meta_data)
         values ($1, $2, now(), '{"full_name":"Fresh Launch"}'::jsonb)
         on conflict (id) do update set
           email = excluded.email,
           email_confirmed_at = excluded.email_confirmed_at,
           raw_user_meta_data = excluded.raw_user_meta_data`,
        [USER_ID, EMAIL],
      );
      await client.query(
        `insert into public.danotch_signup_enrollments(
           email_hash, requested_at, status
         ) values (
           encode(digest(convert_to(lower($1::text), 'utf8'), 'sha256'), 'hex'),
           now() - interval '1 minute',
           'pending'
         )
         on conflict (email_hash) do update set
           user_id = null,
           requested_at = excluded.requested_at,
           verified_at = null,
           status = 'pending'`,
        [EMAIL],
      );

      await client.query('set local role danotch_bootstrap');
      const first = await client.query(
        `select public.danotch_provision_verified_user(
           $1, $2, $3, $4, $5::text[]
         ) as provision`,
        [USER_ID, EMAIL, 'Fresh Launch', TRIAL_HASH, APPS],
      );
      assert.deepEqual(first.rows[0].provision, {
        profile_ready: true,
        apps_ready: true,
        trial_ready: true,
        completed_at: first.rows[0].provision.completed_at,
      });
      assert.ok(first.rows[0].provision.completed_at);

      const profile = await client.query(
        `select email, full_name, billing_status, trial_started_at, trial_ends_at,
                lifetime_purchased_at
         from public.danotch_user_profiles where id = $1`,
        [USER_ID],
      );
      assert.equal(profile.rows[0].email, EMAIL);
      assert.equal(profile.rows[0].full_name, 'Fresh Launch');
      assert.equal(profile.rows[0].billing_status, 'trialing');
      assert.equal(profile.rows[0].lifetime_purchased_at, null);
      assert.ok(profile.rows[0].trial_started_at);
      assert.ok(profile.rows[0].trial_ends_at);
      assert.ok(
        new Date(profile.rows[0].trial_ends_at).getTime()
          > new Date(profile.rows[0].trial_started_at).getTime(),
      );

      const apps = await client.query(
        `select app_type, active from public.danotch_connected_apps
         where user_id = $1 order by app_type`,
        [USER_ID],
      );
      assert.deepEqual(
        apps.rows,
        [...APPS].sort().map((app_type) => ({ app_type, active: false })),
      );

      await client.query(
        `select public.danotch_provision_verified_user(
           $1, $2, $3, $4, $5::text[]
         )`,
        [USER_ID, EMAIL, 'Changed Name', TRIAL_HASH, APPS],
      );
      await client.query('reset role');
      const idempotency = await client.query(
        `select
           (select attempts from public.danotch_verified_provisioning where user_id = $1) as attempts,
           (select count(*)::integer from public.danotch_capability_quota_events
             where capability = 'trial' and subject_hash = $2) as trial_events`,
        [USER_ID, TRIAL_HASH],
      );
      assert.deepEqual(idempotency.rows[0], { attempts: 2, trial_events: 1 });
    } finally {
      await client.query('rollback');
    }
  });
});
