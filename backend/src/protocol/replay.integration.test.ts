import assert from 'node:assert/strict';
import { test } from 'node:test';
import { createHash } from 'node:crypto';
import type { Client } from 'pg';
import { databaseUrl, withClient } from '../db/test-db.ts';

const OWNER = '90000000-0000-4000-8000-000000000001';
const DEVICE = '90000000-0000-4000-8000-000000000002';
const HASH = 'a'.repeat(64);
const IMAGE = `sha256:${'b'.repeat(64)}`;

async function denied(client: Client, query: string, values: unknown[]) {
  await client.query('savepoint expected_denial');
  await assert.rejects(client.query(query, values));
  await client.query('rollback to savepoint expected_denial');
}

async function offeredRun(client: Client, suffix: string) {
  const runId = `91000000-0000-4000-8000-0000000000${suffix}`;
  const actionId = `92000000-0000-4000-8000-0000000000${suffix}`;
  await client.query('set local role danotch_runner');
  await client.query(
    `select public.danotch_create_run($1, $2, $3, $4, '{}'::jsonb, 1)`,
    [runId, OWNER, DEVICE, `replay-${suffix}`],
  );
  await client.query(
    `insert into public.danotch_local_action_requests(
      id, run_id, user_id, device_id, registry_version, action_type,
      normalized_parameters, parameters_hash, capabilities, image_digest,
      workspace_bookmark_id, result_disclosure_policy, expires_at
    ) values (
      $1, $2, $3, $4, '1', 'local.read_file', '{"path":"README.md"}',
      $5, '{"workspace_read":true}', $6, 'workspace-test',
      '{"sensitive_output":false,"upload":false}', now() + interval '10 minutes'
    )`,
    [actionId, runId, OWNER, DEVICE, HASH, IMAGE],
  );
  await client.query(
    `select public.danotch_transition_run(
      $1, $2, gen_random_uuid(), 0, 'waiting_for_device',
      'local_action_offered', jsonb_build_object('actionId', $3::uuid), null
    )`,
    [runId, OWNER, actionId],
  );
  return { runId, actionId };
}

test('database recovery enforces cancellation races, one-use grants, and offline expiry', {
  skip: !databaseUrl,
}, async () => {
  await withClient(async (client) => {
    await client.query('begin');
    try {
      await client.query(
        `insert into auth.users(id) values ($1) on conflict do nothing`,
        [OWNER],
      );
      await client.query(
        `insert into public.danotch_devices(
          id, user_id, display_name, public_key, key_fingerprint
        ) values ($1, $2, 'Replay Mac', 'key', $3)
        on conflict (id) do update set
          status = 'active', current_fence = 0, replay_cursor = 0,
          key_fingerprint = excluded.key_fingerprint`,
        [DEVICE, OWNER, 'c'.repeat(64)],
      );

      const granted = await offeredRun(client, '01');
      await client.query('set local role danotch_fencing');
      const action = await client.query(
        `select action_hash, normalized_parameters, capabilities
         from public.danotch_local_action_requests where id = $1`,
        [granted.actionId],
      );
      const grantId = '93000000-0000-4000-8000-000000000001';
      const grantToken = 'x'.repeat(43);
      const grantHash = createHash('sha256').update(grantToken).digest('hex');
      await client.query(
        `select public.danotch_fenced_claim_approval_and_mint_grant(
          $1, $2, $3, $4, $5, $6, $7, $8, 0, now() + interval '2 minutes'
        )`,
        [
          '94000000-0000-4000-8000-000000000001',
          grantId,
          granted.actionId,
          OWNER,
          DEVICE,
          HASH,
          grantHash,
          grantToken,
        ],
      );
      const consumeValues = [
        '95000000-0000-4000-8000-000000000001',
        grantId,
        granted.actionId,
        OWNER,
        DEVICE,
        grantHash,
        action.rows[0].action_hash,
        HASH,
        action.rows[0].normalized_parameters,
        action.rows[0].capabilities,
        IMAGE,
      ];
      const consumeSql = `select public.danotch_fenced_consume_execution_grant(
        $1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, 0
      )`;
      await client.query(consumeSql, consumeValues);
      await client.query(consumeSql, consumeValues);
      await denied(client, consumeSql, [
        '95000000-0000-4000-8000-000000000009',
        ...consumeValues.slice(1),
      ]);

      const cancelled = await offeredRun(client, '02');
      await client.query('set local role danotch_runner');
      await client.query(
        `select public.danotch_cancel_run(gen_random_uuid(), $1, $2, $3, 'cancelled')`,
        [cancelled.runId, OWNER, DEVICE],
      );
      await client.query('set local role danotch_fencing');
      await denied(
        client,
        `select public.danotch_fenced_claim_approval_and_mint_grant(
          gen_random_uuid(), gen_random_uuid(), $1, $2, $3, $4,
          $5, $6, 0, now() + interval '2 minutes'
        )`,
        [
          cancelled.actionId,
          OWNER,
          DEVICE,
          HASH,
          createHash('sha256').update('y'.repeat(43)).digest('hex'),
          'y'.repeat(43),
        ],
      );

      const expiring = await offeredRun(client, '03');
      await client.query('set local role danotch_runner');
      await client.query(
        `select public.danotch_expire_waiting_device_runs(now() + interval '1 hour')`,
      );
      const expired = await client.query(
        `select state, device_id from public.danotch_runs where id = $1`,
        [expiring.runId],
      );
      assert.deepEqual(expired.rows[0], { state: 'expired', device_id: DEVICE });
    } finally {
      await client.query('rollback');
    }
  });
});
