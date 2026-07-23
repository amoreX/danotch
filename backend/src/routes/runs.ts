import { randomUUID } from 'node:crypto';
import { Router, type RequestHandler } from 'express';
import type { SupabaseClient } from '@supabase/supabase-js';
import {
  getOwnerRun,
  listOwnerRuns,
  type DurableRunRecord,
} from '../protocol/durable-run-store.js';
import { getAdminDb } from '../lib/admin-db.js';
import { userDb } from '../lib/user-db.js';
import { isUuid } from '../devices/device-service.js';

export interface OwnerDeviceSnapshot {
  device: Record<string, unknown>;
  cursor: number;
  runs: Array<Record<string, unknown>>;
  actions: Array<Record<string, unknown>>;
  grants: Array<Record<string, unknown>>;
}

export interface RunRouteStore {
  list(ownerId: string): Promise<DurableRunRecord[]>;
  get(ownerId: string, runId: string): Promise<DurableRunRecord | null>;
  cancel(ownerId: string, runId: string, reason: string): Promise<DurableRunRecord>;
  snapshot(ownerId: string, deviceId: string): Promise<OwnerDeviceSnapshot | null>;
}

export class SupabaseRunRouteStore implements RunRouteStore {
  constructor(private readonly runner: SupabaseClient = getAdminDb('runner')) {}

  list(ownerId: string) {
    return listOwnerRuns(ownerId);
  }

  get(ownerId: string, runId: string) {
    return getOwnerRun(ownerId, runId);
  }

  async cancel(ownerId: string, runId: string, reason: string): Promise<DurableRunRecord> {
    const run = await getOwnerRun(ownerId, runId);
    if (!run) throw new RunRouteError(404, 'run_not_found', 'Run not found');
    if (!run.deviceId) {
      throw new RunRouteError(409, 'run_not_device_bound', 'Run is not bound to a device');
    }
    const { data, error } = await this.runner.rpc('danotch_cancel_run', {
      p_cancellation_id: randomUUID(),
      p_run_id: runId,
      p_user_id: ownerId,
      p_device_id: run.deviceId,
      p_reason: reason,
    });
    if (error || !data) {
      if (/late|terminal/i.test(error?.message ?? '')) {
        throw new RunRouteError(409, 'run_terminal', 'Terminal runs cannot be cancelled');
      }
      throw new Error(error?.message ?? 'Failed to cancel run');
    }
    return getOwnerRun(ownerId, runId) as Promise<DurableRunRecord>;
  }

  async snapshot(ownerId: string, deviceId: string): Promise<OwnerDeviceSnapshot | null> {
    const { data: device, error: deviceError } = await userDb
      .from('danotch_devices')
      .select('id,display_name,status,current_fence,replay_cursor,enrolled_at,revoked_at')
      .eq('id', deviceId)
      .eq('user_id', ownerId)
      .maybeSingle();
    if (deviceError) throw new Error(deviceError.message);
    if (!device) return null;
    const [runs, actions, grants] = await Promise.all([
      userDb
        .from('danotch_runs')
        .select('id,state,revision,checkpoint,terminal_code,waiting_expires_at,created_at,updated_at')
        .eq('user_id', ownerId)
        .eq('device_id', deviceId)
        .order('created_at', { ascending: false })
        .limit(50),
      userDb
        .from('danotch_local_action_requests')
        .select(
          'id,run_id,state,registry_version,action_type,action_hash,normalized_parameters,parameters_hash,capabilities,image_digest,expires_at',
        )
        .eq('user_id', ownerId)
        .eq('device_id', deviceId)
        .not('state', 'in', '("completed","failed","cancelled","expired","rejected")'),
      userDb
        .from('danotch_execution_grants')
        .select(
          'id,action_id,action_hash,parameters_hash,normalized_parameters,capabilities,image_digest,fence,expires_at,consumed_at,revoked_at',
        )
        .eq('user_id', ownerId)
        .eq('device_id', deviceId)
        .is('consumed_at', null)
        .is('revoked_at', null),
    ]);
    for (const result of [runs, actions, grants]) {
      if (result.error) throw new Error(result.error.message);
    }
    return {
      device: device as Record<string, unknown>,
      cursor: Number(device.replay_cursor),
      runs: (runs.data ?? []) as Array<Record<string, unknown>>,
      actions: (actions.data ?? []) as Array<Record<string, unknown>>,
      grants: (grants.data ?? []) as Array<Record<string, unknown>>,
    };
  }
}

class RunRouteError extends Error {
  constructor(
    readonly status: number,
    readonly code: string,
    message: string,
  ) {
    super(message);
  }
}

export function createRunRoutes(options: {
  requireAuth: RequestHandler;
  store?: RunRouteStore;
}): Router {
  const router = Router();
  const store = options.store ?? new SupabaseRunRouteStore();
  router.use(options.requireAuth);

  router.get('/', async (req, res) => {
    try {
      res.json({ runs: await store.list(req.user!.sub) });
    } catch (error) {
      handleError(error, res);
    }
  });

  router.get('/devices/:deviceId/snapshot', async (req, res) => {
    try {
      const deviceId = req.params.deviceId as string;
      if (!isUuid(deviceId)) {
        throw new RunRouteError(400, 'invalid_device_id', 'deviceId must be a UUID');
      }
      const snapshot = await store.snapshot(req.user!.sub, deviceId);
      if (!snapshot) throw new RunRouteError(404, 'device_not_found', 'Device not found');
      res.json({
        protocol_version: 1,
        generated_at: new Date().toISOString(),
        snapshot,
        cursor: snapshot.cursor,
      });
    } catch (error) {
      handleError(error, res);
    }
  });

  router.get('/:runId', async (req, res) => {
    try {
      const runId = req.params.runId as string;
      if (!isUuid(runId)) throw new RunRouteError(400, 'invalid_run_id', 'runId must be a UUID');
      const run = await store.get(req.user!.sub, runId);
      if (!run) throw new RunRouteError(404, 'run_not_found', 'Run not found');
      res.json({ run });
    } catch (error) {
      handleError(error, res);
    }
  });

  router.post('/:runId/cancel', async (req, res) => {
    try {
      const runId = req.params.runId as string;
      if (!isUuid(runId)) throw new RunRouteError(400, 'invalid_run_id', 'runId must be a UUID');
      const reason = req.body?.reason;
      if (reason !== undefined && (typeof reason !== 'string' || reason.length > 500)) {
        throw new RunRouteError(400, 'invalid_reason', 'reason must be at most 500 characters');
      }
      res.json({ run: await store.cancel(req.user!.sub, runId, reason ?? '') });
    } catch (error) {
      handleError(error, res);
    }
  });

  return router;
}

function handleError(error: unknown, res: Parameters<RequestHandler>[1]): void {
  if (error instanceof RunRouteError) {
    res.status(error.status).json({ error: error.message, code: error.code });
    return;
  }
  console.error('[runs] request failed', error);
  res.status(500).json({ error: 'Run operation failed', code: 'run_operation_failed' });
}
