import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import type { Client } from 'pg';
import { asUser, databaseUrl, withClient } from '../db/test-db.ts';

const OWNER_A = '30000000-0000-4000-8000-00000000000a';
const OWNER_B = '30000000-0000-4000-8000-00000000000b';
const DEVICE_A = '31000000-0000-4000-8000-00000000000a';
const DEVICE_B = '31000000-0000-4000-8000-00000000000b';
const RUN_A = '32000000-0000-4000-8000-00000000000a';
const START_A = '33000000-0000-4000-8000-00000000000a';
const RUN_ACTION = '32000000-0000-4000-8000-00000000000c';
const ACTION = '34000000-0000-4000-8000-00000000000a';
const DECISION = '35000000-0000-4000-8000-00000000000a';
const GRANT = '36000000-0000-4000-8000-00000000000a';
const RESULT = '37000000-0000-4000-8000-00000000000a';
const CONSUMPTION = '38000000-0000-4000-8000-00000000000a';
const HASH = 'a'.repeat(64);
const GRANT_TOKEN = 'x'.repeat(43);
const GRANT_HASH = createHash('sha256').update(GRANT_TOKEN).digest('hex');
const IMAGE_DIGEST = `sha256:${'c'.repeat(64)}`;

async function expectDenied(client: Client, sql: string, params: unknown[] = []) {
  await client.query('savepoint denied');
  await assert.rejects(client.query(sql, params));
  await client.query('rollback to savepoint denied');
}

test('durable runner enforces owner/device scope, ordering, and interruption recovery', {
  skip: !databaseUrl,
}, async () => {
  await withClient(async (client) => {
    await client.query(
      `insert into auth.users(id) values ($1), ($2) on conflict do nothing`,
      [OWNER_A, OWNER_B],
    );
    await client.query(
      `insert into public.danotch_devices(
         id, user_id, display_name, public_key, key_fingerprint
       )
       values ($1, $2, 'A', 'key-a', $5), ($3, $4, 'B', 'key-b', $6)
       on conflict (id) do nothing`,
      [DEVICE_A, OWNER_A, DEVICE_B, OWNER_B, 'd'.repeat(64), 'e'.repeat(64)],
    );

    await client.query('begin');
    await client.query('set local role danotch_runner');
    const created = await client.query(
      `select (public.danotch_create_run($1, $2, $3, 'request-a', '{"kind":"chat"}', 1)).*`,
      [RUN_A, OWNER_A, DEVICE_A],
    );
    assert.equal(created.rows[0].state, 'queued');

    await expectDenied(
      client,
      `select public.danotch_create_run(
        gen_random_uuid(), $1, $2, 'forged-device', '{}'::jsonb, 1
      )`,
      [OWNER_A, DEVICE_B],
    );

    const streaming = await client.query(
      `select (public.danotch_transition_run(
        $1, $2, $3, 0, 'provider_streaming', 'provider_stream_started', '{}'::jsonb, null
      )).*`,
      [RUN_A, OWNER_A, START_A],
    );
    assert.equal(streaming.rows[0].revision, '1');

    const duplicate = await client.query(
      `select (public.danotch_transition_run(
        $1, $2, $3, 0, 'provider_streaming', 'provider_stream_started', '{}'::jsonb, null
      )).*`,
      [RUN_A, OWNER_A, START_A],
    );
    assert.equal(duplicate.rows[0].revision, '1');

    await expectDenied(
      client,
      `select public.danotch_transition_run(
        $1, $2, gen_random_uuid(), 0, 'completed', 'run_completed', '{}'::jsonb, null
      )`,
      [RUN_A, OWNER_A],
    );

    const recovered = await client.query(
      `select public.danotch_recover_interrupted_streams() as count`,
    );
    assert.equal(Number(recovered.rows[0].count), 1);
    const final = await client.query(`select state from public.danotch_runs where id = $1`, [RUN_A]);
    assert.equal(final.rows[0].state, 'failed_recoverable');

    await expectDenied(
      client,
      `select public.danotch_transition_run(
        $1, $2, gen_random_uuid(), 2, 'completed', 'run_completed', '{}'::jsonb, null
      )`,
      [RUN_A, OWNER_A],
    );
    await client.query('rollback');
  });
});

test('same owner cannot forge run state, sequence, acknowledgement, or result', {
  skip: !databaseUrl,
}, async () => {
  await withClient(async (client) => {
    await asUser(client, OWNER_A, async () => {
      await expectDenied(
        client,
        `update public.danotch_runs set state = 'completed', revision = 999 where id = $1`,
        [RUN_A],
      );
      await expectDenied(
        client,
        `insert into public.danotch_run_events(
          id, run_id, user_id, device_id, run_sequence, event_type, to_state
        ) values (gen_random_uuid(), $1, $2, $3, 999, 'run_completed', 'completed')`,
        [RUN_A, OWNER_A, DEVICE_A],
      );
      await expectDenied(
        client,
        `insert into public.danotch_event_acknowledgements(
          id, event_id, user_id, device_id, device_sequence, fence
        ) values (gen_random_uuid(), $1, $2, $3, 1, 0)`,
        [START_A, OWNER_A, DEVICE_A],
      );
      await expectDenied(
        client,
        `insert into public.danotch_terminal_results(
          id, run_id, user_id, device_id, status, result
        ) values (gen_random_uuid(), $1, $2, $3, 'completed', '{"forged":true}')`,
        [RUN_A, OWNER_A, DEVICE_A],
      );
      await expectDenied(
        client,
        `select public.danotch_transition_run(
          $1, $2, gen_random_uuid(), 0, 'completed', 'run_completed', '{}'::jsonb, null
        )`,
        [RUN_A, OWNER_A],
      );
    });
  });
});

test('local action decisions are immutable and execution grants are one-use', {
  skip: !databaseUrl,
}, async () => {
  await withClient(async (client) => {
    await client.query(
      `insert into auth.users(id) values ($1) on conflict do nothing`,
      [OWNER_A],
    );
    await client.query(
      `insert into public.danotch_devices(
         id, user_id, display_name, public_key, key_fingerprint
       ) values ($1, $2, 'A', 'key-a', $3)
       on conflict (id) do update set status = 'active', key_fingerprint = excluded.key_fingerprint`,
      [DEVICE_A, OWNER_A, 'd'.repeat(64)],
    );
    await client.query('begin');
    await client.query('set local role danotch_runner');
    await client.query(
      `select public.danotch_create_run($1, $2, $3, 'action-run', '{}'::jsonb, 1)`,
      [RUN_ACTION, OWNER_A, DEVICE_A],
    );
    await client.query(
      `select public.danotch_transition_run(
        $1, $2, gen_random_uuid(), 0, 'provider_streaming',
        'provider_stream_started', '{}'::jsonb, null
      )`,
      [RUN_ACTION, OWNER_A],
    );
    await client.query(
      `select public.danotch_transition_run(
        $1, $2, gen_random_uuid(), 1, 'checkpointed',
        'provider_checkpointed', '{}'::jsonb, '{"boundary":"tool"}'::jsonb
      )`,
      [RUN_ACTION, OWNER_A],
    );
    await client.query(
      `insert into public.danotch_local_action_requests(
        id, run_id, user_id, device_id, registry_version, action_type,
        normalized_parameters, parameters_hash, capabilities, image_digest,
        workspace_bookmark_id, result_disclosure_policy, expires_at
      ) values (
        $1, $2, $3, $4, '1', 'local.read_file', '{"path":"README.md"}',
        $5, '{"workspace_read":true}', $6, 'workspace-test',
        '{"sensitive_output":false,"upload":false}', now() + interval '5 minutes'
      )`,
      [ACTION, RUN_ACTION, OWNER_A, DEVICE_A, HASH, IMAGE_DIGEST],
    );
    await client.query(
      `select public.danotch_transition_run(
        $1, $2, gen_random_uuid(), 2, 'waiting_for_device',
        'local_action_offered', jsonb_build_object('actionId', $3), null
      )`,
      [RUN_ACTION, OWNER_A, ACTION],
    );

    await client.query('set local role danotch_fencing');
    const bound = await client.query(
      `select action_hash, normalized_parameters, capabilities
       from public.danotch_local_action_requests where id = $1`,
      [ACTION],
    );
    const actionHash = bound.rows[0].action_hash as string;
    const decision = await client.query(
      `select public.danotch_fenced_claim_approval_and_mint_grant(
        $1, $2, $3, $4, $5, $6, $7, $8, 0, now() + interval '1 minute'
      ) as grant`,
      [DECISION, GRANT, ACTION, OWNER_A, DEVICE_A, HASH, GRANT_HASH, GRANT_TOKEN],
    );
    assert.equal(decision.rows[0].grant.grant_id, GRANT);
    const duplicateDecision = await client.query(
      `select public.danotch_fenced_claim_approval_and_mint_grant(
        $1, gen_random_uuid(), $3, $4, $5, $6, $7, 'y'::text || repeat('y', 42),
        0, now() + interval '1 minute'
      ) as grant`,
      [
        DECISION, GRANT, ACTION, OWNER_A, DEVICE_A, HASH,
        createHash('sha256').update('y'.repeat(43)).digest('hex'),
      ],
    );
    assert.equal(duplicateDecision.rows[0].grant.grant_id, GRANT);

    await client.query(
      `select public.danotch_fenced_consume_execution_grant(
        $1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, 0
      )`,
      [
        CONSUMPTION, GRANT, ACTION, OWNER_A, DEVICE_A, GRANT_HASH,
        actionHash, HASH, bound.rows[0].normalized_parameters,
        bound.rows[0].capabilities, IMAGE_DIGEST,
      ],
    );
    await client.query(
      `select public.danotch_fenced_consume_execution_grant(
        $1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, 0
      )`,
      [
        CONSUMPTION, GRANT, ACTION, OWNER_A, DEVICE_A, GRANT_HASH,
        actionHash, HASH, bound.rows[0].normalized_parameters,
        bound.rows[0].capabilities, IMAGE_DIGEST,
      ],
    );
    await expectDenied(
      client,
      `select public.danotch_fenced_consume_execution_grant(
        $1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, 0
      )`,
      [
        '38000000-0000-4000-8000-00000000000b',
        GRANT, ACTION, OWNER_A, DEVICE_A, GRANT_HASH,
        actionHash, HASH, bound.rows[0].normalized_parameters,
        bound.rows[0].capabilities, IMAGE_DIGEST,
      ],
    );
    const result = await client.query(
      `select public.danotch_record_action_result(
        $1, $2, $3, $4, $5, 'completed', '{"ok":true}', 0
      ) as state`,
      [RESULT, ACTION, GRANT, OWNER_A, DEVICE_A],
    );
    assert.equal(result.rows[0].state, 'completed');
    const duplicateResult = await client.query(
      `select public.danotch_record_action_result(
        $1, $2, $3, $4, $5, 'completed', '{"ok":true}', 0
      ) as state`,
      [RESULT, ACTION, GRANT, OWNER_A, DEVICE_A],
    );
    assert.equal(duplicateResult.rows[0].state, 'completed');
    await expectDenied(
      client,
      `select public.danotch_cancel_run(gen_random_uuid(), $1, $2, $3, 'late')`,
      [RUN_ACTION, OWNER_A, DEVICE_A],
    );
    await client.query('rollback');
  });
});
