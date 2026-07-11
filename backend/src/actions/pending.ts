import { supabase } from '../lib/supabase.js';
import { executeComposioTool } from '../composio/tools.js';

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
}): Promise<{ id: string } | { error: string }> {
  const { data, error } = await supabase
    .from('danotch_pending_actions')
    .insert({
      user_id: params.userId,
      session_id: params.sessionId,
      action_type: params.actionType,
      summary: params.summary,
      payload: params.payload,
      idempotency_key: crypto.randomUUID(),
    })
    .select('id')
    .single();

  if (error || !data) return { error: error?.message ?? 'Failed to create pending action' };
  return { id: data.id };
}

/** List a user's pending actions (owner-scoped; excludes sensitive payload). */
export async function listPendingActions(userId: string): Promise<Array<Omit<PendingAction, 'payload'>>> {
  const { data, error } = await supabase
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
  const { data, error } = await supabase
    .from('danotch_pending_actions')
    .update({ status: 'rejected', decided_at: new Date().toISOString() })
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
  const { data: claim } = await supabase.rpc('danotch_claim_pending_action', {
    p_action_id: actionId,
    p_user_id: userId,
  });
  if (claim !== 'claimed') {
    return { status: 'noop' };
  }

  const { data: action } = await supabase
    .from('danotch_pending_actions')
    .select('action_type, payload, idempotency_key')
    .eq('id', actionId)
    .eq('user_id', userId)
    .single();

  if (!action) {
    return { status: 'noop' };
  }

  try {
    const result = await executeComposioTool(userId, {
      id: action.idempotency_key,
      name: action.action_type,
      input: action.payload as Record<string, unknown>,
    });
    await supabase
      .from('danotch_pending_actions')
      .update({ status: 'completed', result: result.slice(0, 2000), executed_at: new Date().toISOString() })
      .eq('id', actionId);
    return { status: 'completed', result };
  } catch (err) {
    const message = err instanceof Error ? err.message : 'execution failed';
    // Leave in `executing` for reconciliation — do NOT auto-mark completed or
    // retry, since the downstream side effect may or may not have occurred.
    await supabase
      .from('danotch_pending_actions')
      .update({ error: message })
      .eq('id', actionId);
    return { status: 'failed', error: message };
  }
}
