import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import { test } from 'node:test';
import { asUser, databaseUrl, withClient } from './test-db.ts';

test('trial usage summary keeps daily and lifetime totals account scoped', {
  skip: !databaseUrl,
}, async () => {
  const userA = randomUUID();
  const userB = randomUUID();

  await withClient(async (client) => {
    try {
      for (const [id, label] of [[userA, 'a'], [userB, 'b']] as const) {
        await client.query('insert into auth.users(id) values ($1)', [id]);
        await client.query(
          `insert into public.danotch_user_profiles(
             id, email, full_name, trial_started_at, trial_ends_at, billing_status
           ) values ($1, $2, 'Usage Test', now(), now() + interval '14 days', 'trialing')`,
          [id, `${label}-${id}@example.test`],
        );
      }
      await client.query(
        `insert into public.danotch_trial_usage_daily(
           user_id, usage_day, requests_used, tokens_used, spend_micro_usd
         ) values
           ($1, (now() at time zone 'UTC')::date, 2, 1200, 250000),
           ($1, (now() at time zone 'UTC')::date - 1, 3, 3000, 750000),
           ($2, (now() at time zone 'UTC')::date, 9, 9999, 4999999)`,
        [userA, userB],
      );

      await asUser(client, userA, async () => {
        const result = await client.query(
          'select public.danotch_get_trial_usage_summary() as usage',
        );
        const usage = result.rows[0].usage as Record<string, unknown>;
        assert.match(String(usage.usage_day), /^\d{4}-\d{2}-\d{2}$/);
        assert.deepEqual({
          daily_requests: usage.daily_requests,
          daily_tokens: usage.daily_tokens,
          daily_spend_micro_usd: usage.daily_spend_micro_usd,
          total_requests: usage.total_requests,
          total_tokens: usage.total_tokens,
          total_spend_micro_usd: usage.total_spend_micro_usd,
        }, {
          daily_requests: 2,
          daily_tokens: 1200,
          daily_spend_micro_usd: 250000,
          total_requests: 5,
          total_tokens: 4200,
          total_spend_micro_usd: 1000000,
        });
      });

      await asUser(client, userB, async () => {
        const result = await client.query(
          'select public.danotch_get_trial_usage_summary() as usage',
        );
        assert.equal(result.rows[0].usage.daily_requests, 9);
        assert.equal(result.rows[0].usage.daily_tokens, 9999);
        assert.equal(result.rows[0].usage.total_spend_micro_usd, 4999999);
      });

      await client.query('set role danotch_runner');
      const denied = await client.query(
        `select public.danotch_reserve_trial_usage(
           $1, 1, 101, 10000000, 100, 2
         ) as reservation`,
        [userA],
      );
      await client.query('reset role');
      assert.equal(denied.rows[0].reservation.allowed, false);
      assert.equal(denied.rows[0].reservation.reason, 'daily_spend');
      assert.equal(new Date(denied.rows[0].reservation.reset_at).getUTCHours(), 0);

      await asUser(client, userA, async () => {
        const result = await client.query(
          'select public.danotch_get_trial_usage_summary() as usage',
        );
        assert.equal(result.rows[0].usage.daily_limit_reached, true);
        assert.equal(new Date(result.rows[0].usage.resets_at).getUTCHours(), 0);
      });

      const taskId = randomUUID();
      const resumeAt = new Date(Date.now() + 86_400_000);
      await client.query(
        `insert into public.danotch_scheduled_tasks(
           id, user_id, name, prompt, task_type, interval_ms, next_run_at
         ) values ($1, $2, 'Resume Test', 'test', 'poll', 900000, now() - interval '1 minute')`,
        [taskId, userA],
      );
      await client.query('set role danotch_scheduler');
      const claimed = await client.query(
        `select * from public.danotch_claim_due_schedules('trial-limit-test', 1, 120)`,
      );
      assert.equal(claimed.rows[0].id, taskId);
      const finished = await client.query(
        `select public.danotch_finish_schedule_attempt(
           $1, 'trial-limit-test', $2, 'trial_limit', $3,
           '{"status":"trial_limit","summary":"resumes automatically"}'::jsonb
         ) as outcome`,
        [taskId, claimed.rows[0].lease_token, resumeAt.toISOString()],
      );
      assert.equal(finished.rows[0].outcome, 'updated');
      await client.query('reset role');

      const deferred = await client.query(
        `select enabled, run_state, attempt_count, run_count, next_run_at, last_result
         from public.danotch_scheduled_tasks where id = $1`,
        [taskId],
      );
      assert.equal(deferred.rows[0].enabled, true);
      assert.equal(deferred.rows[0].run_state, 'ready');
      assert.equal(deferred.rows[0].attempt_count, 0);
      assert.equal(deferred.rows[0].run_count, 0);
      assert.ok(new Date(deferred.rows[0].next_run_at).getTime() >= resumeAt.getTime() - 1);
      assert.equal(deferred.rows[0].last_result.status, 'trial_limit');
    } finally {
      await client.query('reset role');
      await client.query('delete from auth.users where id = any($1::uuid[])', [[userA, userB]]);
    }
  });
});
