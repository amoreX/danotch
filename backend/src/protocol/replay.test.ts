import assert from 'node:assert/strict';
import { test } from 'node:test';
import type { SupabaseClient } from '@supabase/supabase-js';
import {
  reconnectContract,
  replayBatchMessages,
  ReplayUnavailableError,
  SupabaseReplayStore,
} from './replay.ts';

const identity = {
  userId: '10000000-0000-4000-8000-000000000001',
  deviceId: '20000000-0000-4000-8000-000000000002',
  fence: 9,
  protocolVersion: 1,
};

test('full-jitter reconnect metadata is bounded and explicit', () => {
  assert.deepEqual(reconnectContract(3, {
    baseDelayMs: 500,
    maxDelayMs: 30_000,
    resetAfterMs: 120_000,
    random: () => 0.5,
  }), {
    strategy: 'exponential_full_jitter',
    baseDelayMs: 500,
    maxDelayMs: 30_000,
    attempt: 3,
    retryAfterMs: 2_000,
    resetAfterMs: 120_000,
  });
});

test('retained replay preserves ordered sequence and durable transition IDs', async () => {
  const db = {
    rpc(name: string, args: Record<string, unknown>) {
      assert.equal(name, 'danotch_prepare_device_replay');
      assert.equal(args.p_device_id, identity.deviceId);
      return Promise.resolve({
        error: null,
        data: {
          mode: 'replay',
          cursor: 4,
          reconnect: reconnectContract(0, {
            baseDelayMs: 500,
            maxDelayMs: 30_000,
            resetAfterMs: 120_000,
            random: () => 0,
          }),
          events: [{
            id: '30000000-0000-4000-8000-000000000003',
            device_sequence: 5,
            event_type: 'local_action_offered',
            transition_id: '40000000-0000-4000-8000-000000000004',
            payload: { action_id: 'a' },
            created_at: '2026-07-21T00:00:00.000Z',
          }],
        },
      });
    },
  } as unknown as SupabaseClient;
  const batch = await new SupabaseReplayStore(db).prepare(identity, 100);
  const messages = replayBatchMessages(batch, 1);
  assert.equal(messages[0].type, 'reconnect_contract');
  assert.deepEqual(messages[1].payload, {
    sequence: 5,
    transition_id: '40000000-0000-4000-8000-000000000004',
    event_type: 'local_action_offered',
    data: { action_id: 'a' },
    created_at: '2026-07-21T00:00:00.000Z',
  });
});

test('expired cursor returns an authoritative snapshot and replacement cursor', async () => {
  const db = {
    rpc() {
      return Promise.resolve({
        error: null,
        data: {
          mode: 'snapshot',
          cursor: 42,
          reconnect: reconnectContract(1, {
            baseDelayMs: 500,
            maxDelayMs: 30_000,
            resetAfterMs: 120_000,
            random: () => 0,
          }),
          snapshot: {
            deviceId: identity.deviceId,
            fence: 9,
            cursor: 42,
            generatedAt: '2026-07-21T00:00:00.000Z',
            runs: [{ id: 'run-a', state: 'waiting_for_device' }],
            actions: [],
            grants: [],
          },
        },
      });
    },
  } as unknown as SupabaseClient;
  const batch = await new SupabaseReplayStore(db).prepare(identity, 100);
  const messages = replayBatchMessages(batch, 1);
  assert.equal(batch.mode, 'snapshot');
  assert.equal(messages[1].type, 'snapshot');
  assert.equal(messages[1].payload.cursor, 42);
});

test('quota or replay storage outage fails closed', async () => {
  const db = {
    rpc() {
      return Promise.resolve({ data: null, error: { message: 'quota store unavailable' } });
    },
  } as unknown as SupabaseClient;
  await assert.rejects(
    new SupabaseReplayStore(db).prepare(identity, 100),
    (error: unknown) =>
      error instanceof ReplayUnavailableError && /quota store unavailable/.test(error.message),
  );
});
