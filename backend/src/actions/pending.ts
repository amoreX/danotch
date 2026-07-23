import { createHash, randomUUID } from 'node:crypto';
import { getAdminDb } from '../lib/admin-db.js';
import { userDb } from '../lib/user-db.js';
import { executeComposioTool } from '../composio/tools.js';
import {
  ACTION_REGISTRY_VERSION,
  classifyAction,
  getActionDeliveryContract,
} from './registry.js';
import { SupabaseQuotaStore, requestQuotaSubject } from '../security/quota-store.js';
import { normalizeActionParameters } from './parameters.js';

const supabase = new Proxy({} as ReturnType<typeof getAdminDb>, {
  get(_target, property) {
    const client = getAdminDb('reconciliation') as unknown as Record<PropertyKey, unknown>;
    const value = client[property];
    return typeof value === 'function' ? value.bind(client) : value;
  },
});
const actionQuota = new SupabaseQuotaStore(getAdminDb('reconciliation'));

async function expirePendingActions(): Promise<void> {
  const { error } = await supabase.rpc('danotch_expire_pending_actions', {
    p_now: new Date().toISOString(),
  });
  if (error) throw new Error('Pending action expiry is unavailable');
}
export type PendingActionStatus =
  | 'pending'
  | 'executing'
  | 'completed'
  | 'rejected'
  | 'expired'
  | 'failed';

export interface PendingAction {
  id: string;
  userId: string;
  sessionId: string | null;
  actionType: string;
  summary: string;
  payload: Record<string, unknown>;
  status: PendingActionStatus;
  result: string | null;
  error: string | null;
  createdAt: string;
  expiresAt: string;
}
/**
 * Create a durable pending action storing the immutable canonical payload. The
 * payload is what will execute verbatim on approval — never re-derived from the
 * model afterwards.
 */
export async function createPendingAction(params: {
  userId: string;
  sessionId: string | null;
  actionType: string;
  summary: string;
  payload: Record<string, unknown>;
  accountId: string;
  deviceId: string;
}): Promise<{ id: string } | { error: string }> {
  const policy = classifyAction(params.actionType, {
    registryVersion: ACTION_REGISTRY_VERSION,
    metadataValidated: true,
  });
  if (policy.kind !== 'approval') {
    return {
      error: `External action denied: ${policy.kind === 'deny' ? policy.reason : 'approval_not_required'}`,
    };
  }
  const contract = getActionDeliveryContract(params.actionType);
  if (!contract || !params.accountId || !params.deviceId) {
    return { error: 'External action denied: owner_account_device_binding_required' };
  }
  const normalizedParameters = normalizeActionParameters(params.payload);
  const parametersHash = createHash('sha256')
    .update(JSON.stringify(normalizedParameters))
    .digest('hex');
  try {
    await actionQuota.consume({
      capability: 'action',
      subject: requestQuotaSubject({ userId: params.userId, deviceId: params.deviceId }),
    });
  } catch {
    return { error: 'External action quota is unavailable' };
  }

  const { data, error } = await supabase
    .from('danotch_pending_actions')
    .insert({
      user_id: params.userId,
      session_id: params.sessionId,
      action_type: params.actionType,
      summary: params.summary,
      payload: normalizedParameters,
      normalized_parameters: normalizedParameters,
      parameters_hash: parametersHash,
      registry_version: ACTION_REGISTRY_VERSION,
      account_id: params.accountId,
      device_id: params.deviceId,
      delivery_semantics: contract.idempotency,
      retry_semantics: contract.retry,
      reconciliation_semantics: contract.reconciliation,
      idempotency_key: randomUUID(),
    })
    .select('id')
    .single();

  if (error || !data) return { error: error?.message ?? 'Failed to create pending action' };
  return { id: data.id };
}

/** List a user's pending actions (owner-scoped; excludes sensitive payload). */
export async function listPendingActions(userId: string): Promise<Array<Omit<PendingAction, 'payload'>>> {
  await expirePendingActions();
  const { data, error } = await userDb
    .from('danotch_pending_actions')
    .select('id, session_id, action_type, summary, status, result, error, created_at, expires_at')
    .eq('user_id', userId)
    .order('created_at', { ascending: false })
    .limit(50);

  if (error || !data) return [];
  return data.map((r) => ({
    id: r.id,
    userId,
    sessionId: r.session_id,
    actionType: r.action_type,
    summary: r.summary,
    status: r.status as PendingActionStatus,
    result: r.result,
    error: r.error,
    createdAt: r.created_at,
    expiresAt: r.expires_at,
  }));
}

/** Reject a pending action (owner-scoped, only while still pending). */
export async function rejectPendingAction(userId: string, actionId: string): Promise<boolean> {
  await expirePendingActions();
  const { data, error } = await supabase
    .from('danotch_pending_actions')
    .update({
      status: 'rejected',
      terminal_decision: 'rejected',
      decided_at: new Date().toISOString(),
    })
    .eq('id', actionId)
    .eq('user_id', userId)
    .eq('status', 'pending')
    .select('id')
    .single();
  return !error && Boolean(data);
}

/**
 * Approve and execute a pending action exactly once.
 *
 * Atomicity: danotch_claim_pending_action moves pending → executing in a single
 * guarded update, so a duplicate approval cannot start a second execution. The
 * stored idempotency key is passed downstream where the Composio operation
 * supports one; otherwise the action stays in `executing` on an ambiguous
 * failure and is left for reconciliation rather than auto-replayed.
 */
export async function approvePendingAction(
  userId: string,
  actionId: string,
): Promise<{ status: 'completed' | 'failed' | 'noop'; result?: string; error?: string }> {
  await expirePendingActions();
  const { data: candidate } = await userDb
    .from('danotch_pending_actions')
    .select('action_type, normalized_parameters, parameters_hash, idempotency_key, account_id, device_id, registry_version, delivery_semantics, retry_semantics, reconciliation_semantics')
    .eq('id', actionId)
    .eq('user_id', userId)
    .eq('status', 'pending')
    .single();
  if (!candidate) {
    return { status: 'noop' };
  }
  const policy = classifyAction(candidate.action_type, {
    registryVersion: candidate.registry_version,
    metadataValidated: Boolean(candidate.account_id && candidate.device_id),
  });
  if (policy.kind !== 'approval') {
    return {
      status: 'failed',
      error: `External action denied: ${policy.kind === 'deny' ? policy.reason : 'approval_not_required'}`,
    };
  }
  const contract = getActionDeliveryContract(candidate.action_type);
  const normalizedHash = createHash('sha256')
    .update(JSON.stringify(normalizeActionParameters(candidate.normalized_parameters)))
    .digest('hex');
  if (
    !contract
    || normalizedHash !== candidate.parameters_hash
    || contract.idempotency !== candidate.delivery_semantics
    || contract.retry !== candidate.retry_semantics
    || contract.reconciliation !== candidate.reconciliation_semantics
  ) {
    return { status: 'failed', error: 'Stored action contract failed integrity validation' };
  }
  const [{ data: account }, { data: device }] = await Promise.all([
    userDb.from('danotch_connected_apps')
      .select('id')
      .eq('user_id', userId)
      .eq('composio_conn_id', candidate.account_id)
      .eq('active', true)
      .single(),
    userDb.from('danotch_devices')
      .select('id')
      .eq('user_id', userId)
      .eq('id', candidate.device_id)
      .eq('status', 'active')
      .single(),
  ]);
  if (!account || !device) {
    return { status: 'failed', error: 'Bound account or device is no longer active' };
  }

  const { data: claim } = await supabase.rpc('danotch_claim_pending_action', {
    p_action_id: actionId,
    p_user_id: userId,
  });
  if (claim !== 'claimed') {
    return { status: 'noop' };
  }

  try {
    const result = await executeComposioTool(userId, {
      id: candidate.idempotency_key,
      name: candidate.action_type,
      input: candidate.normalized_parameters as Record<string, unknown>,
      strictDelivery: true,
    });
    await supabase
      .from('danotch_pending_actions')
      .update({
        status: 'completed',
        terminal_decision: 'completed',
        result: result.slice(0, 2000),
        executed_at: new Date().toISOString(),
      })
      .eq('id', actionId)
      .eq('user_id', userId)
      .eq('status', 'executing');
    return { status: 'completed', result };
  } catch (err) {
    const message = err instanceof Error ? err.message : 'execution failed';
    // A dispatched non-queryable mutation is terminal reconciliation work. It
    // is never returned to pending and never automatically retried.
    await supabase
      .from('danotch_pending_actions')
      .update({
        error: message,
        status: 'failed',
        terminal_decision: 'ambiguous_provider_outcome',
        reconciliation_required: true,
      })
      .eq('id', actionId)
      .eq('user_id', userId)
      .eq('status', 'executing');
    return { status: 'failed', error: message };
  }
}
