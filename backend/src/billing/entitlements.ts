import { supabase } from '../lib/supabase.js';
import { getActiveProviderForUser, getFallbackProvider } from '../providers/factory.js';
import type { LLMProvider } from '../providers/types.js';

const TRIAL_DAYS = 14;

type BillingState = 'trialing' | 'paid' | 'expired';

export type BillingStatus = {
  userId: string;
  billingStatus: BillingState;
  trialStartedAt: string;
  trialEndsAt: string;
  trialDaysRemaining: number;
  lifetimePurchasedAt: string | null;
  hasActiveProvider: boolean;
  activeProvider: string | null;
  canUseServerKey: boolean;
  requiresPurchase: boolean;
  requiresProviderKey: boolean;
};

export class EntitlementError extends Error {
  readonly code: 'profile_not_found' | 'trial_expired' | 'provider_key_required';
  readonly billingStatus?: BillingStatus;

  constructor(
    code: EntitlementError['code'],
    message: string,
    billingStatus?: BillingStatus,
  ) {
    super(message);
    this.name = 'EntitlementError';
    this.code = code;
    this.billingStatus = billingStatus;
  }
}

export async function getBillingStatus(userId: string): Promise<BillingStatus> {
  const { data: profile, error } = await supabase
    .from('danotch_user_profiles')
    .select('id, trial_started_at, trial_ends_at, lifetime_purchased_at, billing_status')
    .eq('id', userId)
    .single();

  if (error || !profile) {
    throw new EntitlementError('profile_not_found', 'Your account profile was not found. Please sign in again.');
  }

  const now = new Date();
  let trialStartedAt = parseDate(profile.trial_started_at) ?? now;
  let trialEndsAt = parseDate(profile.trial_ends_at) ?? addDays(trialStartedAt, TRIAL_DAYS);
  const lifetimePurchasedAt = parseDate(profile.lifetime_purchased_at);

  const missingTrialDates = !profile.trial_started_at || !profile.trial_ends_at;
  if (missingTrialDates) {
    await supabase
      .from('danotch_user_profiles')
      .update({
        trial_started_at: trialStartedAt.toISOString(),
        trial_ends_at: trialEndsAt.toISOString(),
      })
      .eq('id', userId);
  }

  const { data: activeProvider } = await supabase
    .from('danotch_provider_configs')
    .select('provider')
    .eq('user_id', userId)
    .eq('is_active', true)
    .maybeSingle();

  const hasActiveProvider = Boolean(activeProvider?.provider);
  const trialActive = trialEndsAt.getTime() > now.getTime();
  const paid = Boolean(lifetimePurchasedAt) || profile.billing_status === 'paid';
  const billingStatus: BillingState = paid ? 'paid' : trialActive ? 'trialing' : 'expired';
  const trialDaysRemaining = trialActive
    ? Math.max(0, Math.ceil((trialEndsAt.getTime() - now.getTime()) / 86_400_000))
    : 0;

  if (profile.billing_status !== billingStatus) {
    await supabase
      .from('danotch_user_profiles')
      .update({ billing_status: billingStatus })
      .eq('id', userId);
  }

  return {
    userId,
    billingStatus,
    trialStartedAt: trialStartedAt.toISOString(),
    trialEndsAt: trialEndsAt.toISOString(),
    trialDaysRemaining,
    lifetimePurchasedAt: lifetimePurchasedAt?.toISOString() ?? null,
    hasActiveProvider,
    activeProvider: activeProvider?.provider ?? null,
    canUseServerKey: !hasActiveProvider && trialActive,
    requiresPurchase: !paid && !trialActive,
    requiresProviderKey: paid && !trialActive && !hasActiveProvider,
  };
}

export async function markUserPaid(
  userId: string,
  { dodoCustomerId, dodoPaymentId }: { dodoCustomerId: string | null; dodoPaymentId: string },
): Promise<{ alreadyProcessed: boolean }> {
  const { data: profile, error } = await supabase
    .from('danotch_user_profiles')
    .select('id, dodo_payment_id')
    .eq('id', userId)
    .single();

  if (error || !profile) {
    throw new EntitlementError('profile_not_found', `Cannot mark user ${userId} as paid: profile not found.`);
  }

  if (profile.dodo_payment_id === dodoPaymentId) {
    return { alreadyProcessed: true };
  }

  const { error: updateError } = await supabase
    .from('danotch_user_profiles')
    .update({
      billing_status: 'paid',
      lifetime_purchased_at: new Date().toISOString(),
      dodo_customer_id: dodoCustomerId,
      dodo_payment_id: dodoPaymentId,
    })
    .eq('id', userId);

  if (updateError) {
    throw new Error(`Failed to mark user ${userId} as paid (payment ${dodoPaymentId}): ${updateError.message}`);
  }

  return { alreadyProcessed: false };
}

export async function resolveProviderForUser(
  userId: string,
  modelOverride?: string,
): Promise<{ provider: LLMProvider; billingStatus: BillingStatus; source: 'byok' | 'trial_server_key' }> {
  const byokProvider = await getActiveProviderForUser(userId, modelOverride);
  const billingStatus = await getBillingStatus(userId);

  if (byokProvider) {
    return { provider: byokProvider, billingStatus, source: 'byok' };
  }

  if (billingStatus.canUseServerKey) {
    return {
      provider: getFallbackProvider(modelOverride),
      billingStatus,
      source: 'trial_server_key',
    };
  }

  if (billingStatus.requiresPurchase) {
    throw new EntitlementError(
      'trial_expired',
      'Your 14-day trial has ended. Buy Perch for $5 to continue, then add your own provider key.',
      billingStatus,
    );
  }

  throw new EntitlementError(
    'provider_key_required',
    'Add or activate your own provider API key in Settings to continue.',
    billingStatus,
  );
}

function parseDate(value: unknown): Date | null {
  if (typeof value !== 'string' || !value) return null;
  const date = new Date(value);
  return Number.isNaN(date.getTime()) ? null : date;
}

function addDays(date: Date, days: number): Date {
  return new Date(date.getTime() + days * 86_400_000);
}
