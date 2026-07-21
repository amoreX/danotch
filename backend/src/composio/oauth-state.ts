import { createHash, randomBytes } from 'node:crypto';
import { getAdminDb } from '../lib/admin-db.js';

const db = () => getAdminDb('reconciliation');

function digest(value: string): string {
  return createHash('sha256').update(value).digest('hex');
}

export interface OAuthLinkAttempt {
  id: string;
  state: string;
  callbackUrl: string;
  priorAccountId?: string;
  expiresAt: string;
}

export async function beginOAuthLinkAttempt(input: {
  userId: string;
  deviceId: string;
  appType: string;
  toolkitSlug: string;
  callbackBaseUrl: string;
  priorAccountId?: string;
  ttlMs: number;
}): Promise<OAuthLinkAttempt> {
  const callbackBase = new URL(input.callbackBaseUrl);
  if (callbackBase.protocol !== 'https:') {
    throw new Error('OAuth callback origin must use HTTPS');
  }
  const state = randomBytes(32).toString('base64url');
  const expiresAt = new Date(Date.now() + input.ttlMs).toISOString();
  // Provider account identifiers are retained only for bounded reconciliation.
  // Cleanup is opportunistic here and can also be run by the reconciler.
  const { error: cleanupError } = await db().from('danotch_oauth_link_attempts')
    .delete()
    .eq('user_id', input.userId)
    .eq('app_type', input.appType)
    .lt('created_at', new Date(Date.now() - 30 * 24 * 60 * 60_000).toISOString());
  if (cleanupError) throw new Error('Could not enforce OAuth identifier retention');
  const { error: supersedeError } = await db().from('danotch_oauth_link_attempts')
    .update({ status: 'superseded' })
    .eq('user_id', input.userId)
    .eq('app_type', input.appType)
    .eq('status', 'pending')
    .is('consumed_at', null);
  if (supersedeError) throw new Error('Could not supersede the prior OAuth attempt');
  const callback = new URL(`/api/apps/${input.appType}/callback`, input.callbackBaseUrl);
  callback.searchParams.set('state', state);
  const { data, error } = await db().from('danotch_oauth_link_attempts').insert({
    user_id: input.userId,
    device_id: input.deviceId,
    app_type: input.appType,
    toolkit_slug: input.toolkitSlug,
    state_hash: digest(state),
    callback_url: callback.toString(),
    prior_account_id: input.priorAccountId ?? null,
    expires_at: expiresAt,
  }).select('id').single();
  if (error || !data) throw new Error(error?.message ?? 'Could not persist OAuth state');
  return {
    id: data.id,
    state,
    callbackUrl: callback.toString(),
    priorAccountId: input.priorAccountId,
    expiresAt,
  };
}

export async function consumeOAuthCallback(input: {
  state: string;
  appType: string;
}): Promise<
  { ok: true; attemptId: string } | { ok: false; reason: 'invalid_or_expired_state' }
> {
  if (!input.state || !input.appType) {
    return { ok: false, reason: 'invalid_or_expired_state' };
  }
  const { data, error } = await db().from('danotch_oauth_link_attempts')
    .update({ consumed_at: new Date().toISOString() })
    .eq('state_hash', digest(input.state))
    .eq('app_type', input.appType)
    .eq('status', 'pending')
    .is('consumed_at', null)
    .gt('expires_at', new Date().toISOString())
    .select('id, callback_url')
    .single();
  if (error || !data) return { ok: false, reason: 'invalid_or_expired_state' };
  const callback = new URL(data.callback_url);
  if (
    callback.pathname !== `/api/apps/${input.appType}/callback`
    || callback.searchParams.get('state') !== input.state
  ) {
    await db().from('danotch_oauth_link_attempts')
      .update({ status: 'failed' })
      .eq('id', data.id);
    return { ok: false, reason: 'invalid_or_expired_state' };
  }
  return { ok: true, attemptId: data.id };
}

export async function failOAuthLinkAttempt(attemptId: string, userId: string): Promise<void> {
  await db().from('danotch_oauth_link_attempts')
    .update({ status: 'failed' })
    .eq('id', attemptId)
    .eq('user_id', userId)
    .eq('status', 'pending');
}

export async function confirmOAuthReplacement(input: {
  attemptId: string;
  userId: string;
  deviceId: string;
  appType: string;
  candidateAccountId: string;
}): Promise<boolean> {
  const { data, error } = await db().from('danotch_oauth_link_attempts')
    .update({
      status: 'confirmed',
      candidate_account_id: input.candidateAccountId,
    })
    .eq('id', input.attemptId)
    .eq('user_id', input.userId)
    .eq('device_id', input.deviceId)
    .eq('app_type', input.appType)
    .eq('status', 'pending')
    .not('consumed_at', 'is', null)
    .gt('expires_at', new Date().toISOString())
    .select('id')
    .single();
  return !error && Boolean(data);
}

export async function getOAuthAttempt(input: {
  attemptId: string;
  userId: string;
  deviceId: string;
  appType: string;
}): Promise<{ priorAccountId?: string; callbackReceived: boolean } | null> {
  const { data, error } = await db().from('danotch_oauth_link_attempts')
    .select('prior_account_id, consumed_at')
    .eq('id', input.attemptId)
    .eq('user_id', input.userId)
    .eq('device_id', input.deviceId)
    .eq('app_type', input.appType)
    .eq('status', 'pending')
    .gt('expires_at', new Date().toISOString())
    .single();
  if (error || !data) return null;
  return {
    priorAccountId: data.prior_account_id ?? undefined,
    callbackReceived: Boolean(data.consumed_at),
  };
}
