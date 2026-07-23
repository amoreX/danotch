import type { SupabaseClient } from '@supabase/supabase-js';
import { userDb } from '../lib/user-db.js';
import { getAdminDb } from '../lib/admin-db.js';
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
  readonly code: 'profile_not_found' | 'trial_expired' | 'provider_key_required' | 'operational';
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

// Payment recording outcomes returned by the danotch_record_payment RPC.
export type PaymentOutcome = 'granted' | 'duplicate' | 'unknown_profile' | 'rejected';

export async function getBillingStatus(
  userId: string,
  db: SupabaseClient = userDb,
): Promise<BillingStatus> {
  const { data: profile, error } = await db
    .from('danotch_user_profiles')
    .select('id, trial_started_at, trial_ends_at, lifetime_purchased_at, billing_status')
    .eq('id', userId)
    .single();

  if (error) {
    // PGRST116 = no rows returned → the profile genuinely doesn't exist.
    // Any other error is an operational/database failure and must not be
    // conflated with a missing profile (the client logs out on not-found).
    if ((error as { code?: string }).code === 'PGRST116') {
      throw new EntitlementError('profile_not_found', 'Your account profile was not found. Please sign in again.');
    }
    throw new EntitlementError('operational', `Billing status is temporarily unavailable: ${error.message}`);
  }
  if (!profile) {
    throw new EntitlementError('profile_not_found', 'Your account profile was not found. Please sign in again.');
  }

  const now = new Date();
  const trialStartedAt = parseDate(profile.trial_started_at) ?? now;
  const trialEndsAt = parseDate(profile.trial_ends_at) ?? addDays(trialStartedAt, TRIAL_DAYS);
  const lifetimePurchasedAt = parseDate(profile.lifetime_purchased_at);

  const { data: activeProvider } = await db
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

/**
 * Create a server-owned checkout record before redirecting to Dodo. The webhook
 * can only grant an entitlement when a verified payment matches one of these
 * records for the authenticated user (product, amount, currency, unexpired).
 * Returns the record id so the caller can attach the Dodo session id afterwards.
 */
export async function createCheckoutRecord(
  userId: string,
  {
    productId,
    expectedAmount,
    expectedCurrency,
    expectedQuantity,
    environment,
  }: {
    productId: string;
    expectedAmount: number;
    expectedCurrency: string;
    expectedQuantity: number;
    environment: string;
  },
): Promise<string> {
  const { data, error } = await getAdminDb('webhook')
    .from('danotch_checkout_records')
    .insert({
      user_id: userId,
      product_id: productId,
      expected_amount: expectedAmount,
      expected_currency: expectedCurrency.toUpperCase(),
      expected_quantity: expectedQuantity,
      environment,
    })
    .select('id')
    .single();

  if (error || !data) {
    throw new Error(`Failed to create checkout record: ${error?.message ?? 'unknown error'}`);
  }
  return data.id;
}

export async function attachCheckoutSession(recordId: string, dodoSessionId: string): Promise<void> {
  await getAdminDb('webhook')
    .from('danotch_checkout_records')
    .update({ dodo_session_id: dodoSessionId })
    .eq('id', recordId);
}

/**
 * Record a verified payment and grant the entitlement atomically via RPC.
 * The RPC consumes a matching checkout record, dedupes on delivery/payment id,
 * and grants paid status on first eligible payment only. It never throws for a
 * business outcome; a thrown error here means an operational/database failure
 * that the caller should treat as retryable (non-2xx to Dodo).
 */
export async function recordPayment(params: {
  deliveryId: string | null;
  paymentId: string;
  claimedUserId: string;
  dodoCustomerId: string | null;
  eventType: string;
  amount: number | null;
  currency: string | null;
  productId: string | null;
}): Promise<PaymentOutcome> {
  const { data, error } = await getAdminDb('webhook').rpc('danotch_record_payment', {
    p_delivery_id: params.deliveryId,
    p_payment_id: params.paymentId,
    p_claimed_user_id: params.claimedUserId,
    p_customer_id: params.dodoCustomerId,
    p_event_type: params.eventType,
    p_amount: params.amount,
    p_currency: params.currency ? params.currency.toUpperCase() : null,
    p_product_id: params.productId,
  });

  if (error) {
    throw new Error(`recordPayment RPC failed for payment ${params.paymentId}: ${error.message}`);
  }

  return (data as PaymentOutcome) ?? 'rejected';
}

export async function resolveProviderForUser(
  userId: string,
  modelOverride?: string,
  db: SupabaseClient = userDb,
): Promise<{ provider: LLMProvider; billingStatus: BillingStatus; source: 'byok' | 'trial_server_key' }> {
  const byokProvider = await getActiveProviderForUser(userId, modelOverride);
  const billingStatus = await getBillingStatus(userId, db);

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
