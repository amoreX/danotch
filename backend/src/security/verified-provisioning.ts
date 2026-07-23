import type { User } from '@supabase/supabase-js';
import { COMPOSIO_APPS } from '../composio/tools.js';
import { getAdminDb } from '../lib/admin-db.js';
import { hashQuotaSubject } from './quota-store.js';
import { isEmailVerified } from './identity-state.js';

export async function provisionVerifiedUser(user: User): Promise<void> {
  if (!isEmailVerified(user) || !user.email) {
    throw new Error('verified_email_required');
  }
  const metadataName = typeof user.user_metadata?.full_name === 'string'
    ? user.user_metadata.full_name.trim()
    : '';
  const fallbackName = user.email.split('@')[0];
  const { data, error } = await getAdminDb('bootstrap').rpc('danotch_provision_verified_user', {
    p_user_id: user.id,
    p_email: user.email,
    p_full_name: metadataName || fallbackName,
    p_trial_subject_hash: hashQuotaSubject(`verified-user:${user.id}`),
    p_apps: COMPOSIO_APPS.map((app) => app.appType),
  });
  if (error || !data) {
    throw new Error(error?.message ?? 'verified_user_provisioning_failed');
  }
}
