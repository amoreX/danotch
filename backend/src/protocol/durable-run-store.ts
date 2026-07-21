import type { SupabaseClient } from '@supabase/supabase-js';
import { getAdminDb } from '../lib/admin-db.js';
import { SupabaseQuotaStore, requestQuotaSubject, type QuotaStore } from '../security/quota-store.js';
import { userDb } from '../lib/user-db.js';
import { PROTOCOL_VERSION } from './schemas.js';
import type { RunEventType, RunState } from './run-state.js';

export interface DurableRunRecord {
  id: string;
  userId: string;
  deviceId: string | null;
  state: RunState;
  revision: number;
  input: Record<string, unknown>;
  checkpoint: Record<string, unknown> | null;
  terminalCode: string | null;
  terminalResult: Record<string, unknown> | null;
  createdAt: string;
  updatedAt: string;
  terminalAt: string | null;
}

type DatabaseRun = {
  id: string;
  user_id: string;
  device_id: string | null;
  state: RunState;
  revision: number;
  input: Record<string, unknown>;
  checkpoint: Record<string, unknown> | null;
  terminal_code: string | null;
  created_at: string;
  updated_at: string;
  terminal_at: string | null;
};

function mapRun(
  row: DatabaseRun,
  terminalResult: Record<string, unknown> | null = null,
): DurableRunRecord {
  return {
    id: row.id,
    userId: row.user_id,
    deviceId: row.device_id,
    state: row.state,
    revision: Number(row.revision),
    input: row.input,
    checkpoint: row.checkpoint,
    terminalCode: row.terminal_code,
    terminalResult,
    createdAt: row.created_at,
    updatedAt: row.updated_at,
    terminalAt: row.terminal_at,
  };
}

export class DurableRunStore {
  private readonly quota: QuotaStore;

  constructor(
    private readonly db: SupabaseClient = getAdminDb('runner'),
    quota?: QuotaStore,
  ) {
    this.quota = quota ?? new SupabaseQuotaStore(db);
  }

  async create(params: {
    runId: string;
    ownerId: string;
    deviceId: string | null;
    idempotencyKey: string;
    input: Record<string, unknown>;
  }): Promise<DurableRunRecord> {
    await this.quota.consume({
      capability: 'storage',
      subject: requestQuotaSubject({ userId: params.ownerId, deviceId: params.deviceId ?? undefined }),
      idempotencyKey: params.idempotencyKey,
    });
    const { data, error } = await this.db.rpc('danotch_create_run', {
      p_run_id: params.runId,
      p_user_id: params.ownerId,
      p_device_id: params.deviceId,
      p_idempotency_key: params.idempotencyKey,
      p_input: params.input,
      p_protocol_version: PROTOCOL_VERSION,
    });
    if (error || !data) throw new Error(error?.message ?? 'Failed to create durable run');
    return mapRun(data as DatabaseRun);
  }

  async transition(
    run: DurableRunRecord,
    params: {
      transitionId: string;
      targetState: RunState;
      eventType: RunEventType;
      payload?: Record<string, unknown>;
      checkpoint?: Record<string, unknown> | null;
    },
  ): Promise<DurableRunRecord> {
    const { data, error } = await this.db.rpc('danotch_transition_run', {
      p_run_id: run.id,
      p_user_id: run.userId,
      p_transition_id: params.transitionId,
      p_expected_revision: run.revision,
      p_target_state: params.targetState,
      p_event_type: params.eventType,
      p_payload: params.payload ?? {},
      p_checkpoint: params.checkpoint ?? null,
    });
    if (error || !data) throw new Error(error?.message ?? 'Failed to transition durable run');
    return mapRun(data as DatabaseRun);
  }

  async recoverInterruptedStreams(): Promise<number> {
    const { data, error } = await this.db.rpc('danotch_recover_interrupted_streams');
    if (error) throw new Error(error.message);
    return Number(data ?? 0);
  }
}

export async function getOwnerRun(ownerId: string, runId: string): Promise<DurableRunRecord | null> {
  const { data, error } = await userDb
    .from('danotch_runs')
    .select(
      'id, user_id, device_id, state, revision, input, checkpoint, terminal_code, created_at, updated_at, terminal_at',
    )
    .eq('id', runId)
    .eq('user_id', ownerId)
    .maybeSingle();
  if (error) throw new Error(error.message);
  if (!data) return null;
  const { data: terminal, error: terminalError } = await userDb
    .from('danotch_terminal_results')
    .select('result')
    .eq('run_id', runId)
    .eq('user_id', ownerId)
    .maybeSingle();
  if (terminalError) throw new Error(terminalError.message);
  return mapRun(
    data as DatabaseRun,
    terminal ? terminal.result as Record<string, unknown> : null,
  );
}

export async function listOwnerRuns(ownerId: string): Promise<DurableRunRecord[]> {
  const { data, error } = await userDb
    .from('danotch_runs')
    .select(
      'id, user_id, device_id, state, revision, input, checkpoint, terminal_code, created_at, updated_at, terminal_at',
    )
    .eq('user_id', ownerId)
    .order('created_at', { ascending: false })
    .limit(50);
  if (error) throw new Error(error.message);
  const rows = (data ?? []) as DatabaseRun[];
  if (rows.length === 0) return [];
  const { data: terminal, error: terminalError } = await userDb
    .from('danotch_terminal_results')
    .select('run_id, result')
    .eq('user_id', ownerId)
    .in('run_id', rows.map((row) => row.id));
  if (terminalError) throw new Error(terminalError.message);
  const results = new Map(
    (terminal ?? []).map((row) => [
      row.run_id as string,
      row.result as Record<string, unknown>,
    ]),
  );
  return rows.map((row) => mapRun(row, results.get(row.id) ?? null));
}
