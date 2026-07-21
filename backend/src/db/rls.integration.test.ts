import { test } from 'node:test';
import assert from 'node:assert/strict';
import type { Client } from 'pg';
import { asUser, databaseUrl, withClient } from './test-db.ts';

const USER_A = '00000000-0000-4000-8000-00000000000a';
const USER_B = '00000000-0000-4000-8000-00000000000b';
const THREAD_A = '10000000-0000-4000-8000-00000000000a';
const THREAD_B = '10000000-0000-4000-8000-00000000000b';
const ACTION_A = '20000000-0000-4000-8000-00000000000a';

async function expectDenied(client: Client, sql: string, params: unknown[] = []) {
  await client.query('savepoint denied_operation');
  await assert.rejects(client.query(sql, params));
  await client.query('rollback to savepoint denied_operation');
}

test('RLS denies anonymous/cross-tenant access and forged ownership', {
  skip: !databaseUrl,
}, async () => {
  await withClient(async (client) => {
    await client.query(
      `insert into auth.users(id) values ($1), ($2) on conflict do nothing`,
      [USER_A, USER_B],
    );
    await client.query(
      `insert into public.danotch_user_profiles(id, email, full_name)
       values ($1, 'a@example.test', 'A'), ($2, 'b@example.test', 'B')
       on conflict (id) do nothing`,
      [USER_A, USER_B],
    );
    await client.query(
      `insert into public.danotch_threads(id, user_id, title)
       values ($1, $2, 'A secret'), ($3, $4, 'B secret')
       on conflict (id) do nothing`,
      [THREAD_A, USER_A, THREAD_B, USER_B],
    );

    await client.query('begin');
    await client.query('set local role anon');
    await assert.rejects(client.query('select * from public.danotch_threads'));
    await client.query('rollback');

    await asUser(client, USER_A, async () => {
      const { rows } = await client.query(
        'select id, title from public.danotch_threads order by id',
      );
      assert.deepEqual(rows, [{ id: THREAD_A, title: 'A secret' }]);
      await expectDenied(
        client,
        `insert into public.danotch_threads(id, user_id, title) values (gen_random_uuid(), $1, 'forged')`,
        [USER_B],
      );
      await expectDenied(
        client,
        `update public.danotch_threads set user_id = $1 where id = $2`,
        [USER_B, THREAD_A],
      );
      const deleted = await client.query(
        'delete from public.danotch_threads where id = $1 returning id',
        [THREAD_B],
      );
      assert.equal(deleted.rowCount, 0);
    });
  });
});

test('owners cannot forge server-authoritative action or notification transitions', {
  skip: !databaseUrl,
}, async () => {
  await withClient(async (client) => {
    await client.query(`insert into auth.users(id) values ($1) on conflict do nothing`, [USER_A]);
    await client.query(
      `insert into public.danotch_user_profiles(id, email, full_name)
       values ($1, 'a@example.test', 'A') on conflict (id) do nothing`,
      [USER_A],
    );
    await client.query(
      `insert into public.danotch_pending_actions
        (id, user_id, action_type, summary, payload, idempotency_key)
       values ($1, $2, 'GMAIL_SEND_EMAIL', 'draft', '{}'::jsonb, 'key-a')
       on conflict (id) do nothing`,
      [ACTION_A, USER_A],
    );
    const notification = await client.query(
      `insert into public.danotch_notifications(user_id, source, title, body)
       values ($1, 'test', 'title', 'server body') returning id`,
      [USER_A],
    );

    await asUser(client, USER_A, async () => {
      const actions = await client.query(
        'select id, status from public.danotch_pending_actions where id = $1',
        [ACTION_A],
      );
      assert.equal(actions.rows[0].status, 'pending');
      await expectDenied(
        client,
        `update public.danotch_pending_actions
         set status = 'completed', result = 'forged' where id = $1`,
        [ACTION_A],
      );
      await expectDenied(
        client,
        `update public.danotch_notifications set body = 'forged' where id = $1`,
        [notification.rows[0].id],
      );
      const marked = await client.query(
        `update public.danotch_notifications set read = true where id = $1 returning read`,
        [notification.rows[0].id],
      );
      assert.equal(marked.rows[0].read, true);
    });
  });
});

test('durable protocol rows are owner/device scoped and owner writes are denied', {
  skip: !databaseUrl,
}, async () => {
  const deviceA = '40000000-0000-4000-8000-00000000000a';
  const deviceB = '40000000-0000-4000-8000-00000000000b';
  const runA = '41000000-0000-4000-8000-00000000000a';
  const runB = '41000000-0000-4000-8000-00000000000b';
  await withClient(async (client) => {
    await client.query(
      `insert into auth.users(id) values ($1), ($2) on conflict do nothing`,
      [USER_A, USER_B],
    );
    await client.query(
      `insert into public.danotch_devices(
         id, user_id, display_name, public_key, key_fingerprint
       )
       values ($1, $2, 'A', 'key-a', $5), ($3, $4, 'B', 'key-b', $6)
       on conflict (id) do nothing`,
      [deviceA, USER_A, deviceB, USER_B, '1'.repeat(64), '2'.repeat(64)],
    );
    await client.query(
      `insert into public.danotch_runs(
        id, user_id, device_id, idempotency_key, input
       ) values
        ($1, $2, $3, 'rls-a', '{}'::jsonb),
        ($4, $5, $6, 'rls-b', '{}'::jsonb)
       on conflict (id) do nothing`,
      [runA, USER_A, deviceA, runB, USER_B, deviceB],
    );

    await asUser(client, USER_A, async () => {
      const devices = await client.query(`select id from public.danotch_devices order by id`);
      assert.deepEqual(devices.rows, [{ id: deviceA }]);
      const runs = await client.query(`select id, device_id from public.danotch_runs order by id`);
      assert.deepEqual(runs.rows, [{ id: runA, device_id: deviceA }]);
      await expectDenied(
        client,
        `insert into public.danotch_runs(
          id, user_id, device_id, idempotency_key, input
        ) values (gen_random_uuid(), $1, $2, 'forged', '{}'::jsonb)`,
        [USER_A, deviceA],
      );
      await expectDenied(
        client,
        `update public.danotch_runs set state = 'completed' where id = $1`,
        [runA],
      );
      await expectDenied(client, 'select * from public.danotch_protocol_quota_config');
      await expectDenied(client, 'select * from public.danotch_reconnect_attempts');
    });
  });
});
