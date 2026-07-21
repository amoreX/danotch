import { randomUUID } from 'node:crypto';
import type { SupabaseClient } from '@supabase/supabase-js';
import { requestQuotaSubject, type QuotaStore } from '../security/quota-store.js';

export interface ReplayIdentity {
  userId: string;
  deviceId: string;
  fence: number;
  protocolVersion: number;
}

export interface RetainedDeviceEvent {
  id: string;
  sequence: number;
  type: string;
  transitionId: string;
  payload: Record<string, unknown>;
  createdAt: string;
}

export interface DeviceSnapshot {
  deviceId: string;
  fence: number;
  cursor: number;
  generatedAt: string;
  runs: Array<Record<string, unknown>>;
  actions: Array<Record<string, unknown>>;
  grants: Array<Record<string, unknown>>;
}

export interface ReconnectContract {
  strategy: 'exponential_full_jitter';
  baseDelayMs: number;
  maxDelayMs: number;
  attempt: number;
  retryAfterMs: number;
  resetAfterMs: number;
}

export type ReplayBatch =
  | {
      mode: 'replay';
      cursor: number;
      events: RetainedDeviceEvent[];
      reconnect: ReconnectContract;
    }
  | {
      mode: 'snapshot';
      cursor: number;
      snapshot: DeviceSnapshot;
      reconnect: ReconnectContract;
    };

export interface ReplayStore {
  prepare(identity: ReplayIdentity, limit: number): Promise<ReplayBatch>;
  expireWaitingRuns(now: string): Promise<number>;
}

export class ReplayUnavailableError extends Error {
  readonly code = 'replay_unavailable';
}

export function reconnectContract(
  attempt: number,
  options: {
    baseDelayMs: number;
    maxDelayMs: number;
    resetAfterMs: number;
    random?: () => number;
  },
): ReconnectContract {
  const boundedAttempt = Math.max(0, Math.min(30, Math.trunc(attempt)));
  const ceiling = Math.min(
    options.maxDelayMs,
    options.baseDelayMs * (2 ** boundedAttempt),
  );
  const random = options.random ?? Math.random;
  return {
    strategy: 'exponential_full_jitter',
    baseDelayMs: options.baseDelayMs,
    maxDelayMs: options.maxDelayMs,
    attempt: boundedAttempt,
    retryAfterMs: Math.floor(Math.max(0, Math.min(1, random())) * ceiling),
    resetAfterMs: options.resetAfterMs,
  };
}

type DatabaseReplayEvent = {
  id: string;
  device_sequence: number;
  event_type: string;
  transition_id?: string;
  payload: Record<string, unknown>;
  created_at: string;
};

function mapEvent(row: DatabaseReplayEvent): RetainedDeviceEvent {
  return {
    id: row.id,
    sequence: Number(row.device_sequence),
    type: row.event_type,
    transitionId: row.transition_id ?? row.id,
    payload: row.payload,
    createdAt: row.created_at,
  };
}

export class SupabaseReplayStore implements ReplayStore {
  constructor(private readonly db: SupabaseClient, private readonly quota?: QuotaStore) {}

  async prepare(identity: ReplayIdentity, limit: number): Promise<ReplayBatch> {
    if (this.quota) {
      await this.quota.consume({
        capability: 'replay',
        subject: requestQuotaSubject({ userId: identity.userId, deviceId: identity.deviceId }),
      });
    }
    const { data, error } = await this.db.rpc('danotch_prepare_device_replay', {
      p_user_id: identity.userId,
      p_device_id: identity.deviceId,
      p_fence: identity.fence,
      p_limit: limit,
      p_attempt_id: randomUUID(),
    });
    if (error || !data) {
      throw new ReplayUnavailableError(error?.message ?? 'Replay storage is unavailable');
    }
    const value = data as {
      mode: 'replay' | 'snapshot';
      cursor: number;
      events?: DatabaseReplayEvent[];
      snapshot?: DeviceSnapshot;
      reconnect: ReconnectContract;
    };
    if (value.mode === 'snapshot') {
      if (!value.snapshot) throw new ReplayUnavailableError('Replay snapshot was not returned');
      return {
        mode: 'snapshot',
        cursor: Number(value.cursor),
        snapshot: value.snapshot,
        reconnect: value.reconnect,
      };
    }
    return {
      mode: 'replay',
      cursor: Number(value.cursor),
      events: (value.events ?? []).map(mapEvent),
      reconnect: value.reconnect,
    };
  }

  async expireWaitingRuns(now: string): Promise<number> {
    const { data, error } = await this.db.rpc('danotch_expire_waiting_device_runs', {
      p_now: now,
    });
    if (error) throw new ReplayUnavailableError(error.message);
    return Number(data ?? 0);
  }
}

export function replayBatchMessages(batch: ReplayBatch, version: number) {
  const hello = {
    v: version,
    type: 'reconnect_contract' as const,
    id: randomUUID(),
    payload: {
      cursor: batch.cursor,
      replay_mode: batch.mode,
      ...batch.reconnect,
    },
  };
  if (batch.mode === 'snapshot') {
    return [
      hello,
      {
        v: version,
        type: 'snapshot' as const,
        id: randomUUID(),
        payload: {
          cursor: batch.cursor,
          snapshot: batch.snapshot,
        },
      },
    ];
  }
  return [
    hello,
    ...batch.events.map((event) => ({
      v: version,
      type: 'event' as const,
      id: event.id,
      payload: {
        sequence: event.sequence,
        transition_id: event.transitionId,
        event_type: event.type,
        data: event.payload,
        created_at: event.createdAt,
      },
    })),
  ];
}
