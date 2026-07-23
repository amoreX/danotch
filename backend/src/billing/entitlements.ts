import type { SupabaseClient } from '@supabase/supabase-js';
import { config } from '../config.js';
import { userDb } from '../lib/user-db.js';
import { getAdminDb } from '../lib/admin-db.js';
import {
  getActiveProviderForUser,
  getFallbackProvider,
  ProviderLookupError,
} from '../providers/factory.js';
import type { LLMProvider } from '../providers/types.js';
import { MeteredTrialProvider } from './trial-provider.js';

const TRIAL_DAYS = 14;

type BillingState = 'trialing' | 'paid' | 'expired' | 'revoked';

export type TrialUsageSummary = {
  usageDay: string;
  dailyRequests: number;
  dailyTokens: number;
  dailySpendMicroUsd: number;
  dailySpendLimitMicroUsd: number;
  dailyLimitReached: boolean;
  resetsAt: string;
  totalRequests: number;
  totalTokens: number;
  totalSpendMicroUsd: number;
};

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
  trialUsage: TrialUsageSummary;
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
    .select(
      'id, trial_started_at, trial_ends_at, lifetime_purchased_at, lifetime_revoked_at, billing_status',
    )
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

  const { data: activeProvider, error: providerError } = await db
    .from('danotch_provider_configs')
    .select('provider')
    .eq('user_id', userId)
    .eq('is_active', true)
    .maybeSingle();
  if (providerError) {
    throw new EntitlementError(
      'operational',
      `Provider status is temporarily unavailable: ${providerError.message}`,
    );
  }

  const { data: usageData, error: usageError } = await db.rpc(
    'danotch_get_trial_usage_summary',
  );
  if (usageError || !usageData) {
    throw new EntitlementError(
      'operational',
      `Trial usage is temporarily unavailable: ${usageError?.message ?? 'invalid response'}`,
    );
  }
  const usage = usageData as Record<string, unknown>;
  const usageDay = usage.usage_day;
  const dailyRequests = Number(usage.daily_requests);
  const dailyTokens = Number(usage.daily_tokens);
  const dailySpendMicroUsd = Number(usage.daily_spend_micro_usd);
  const dailyLimitReached = usage.daily_limit_reached;
  const resetsAt = usage.resets_at;
  const totalRequests = Number(usage.total_requests);
  const totalTokens = Number(usage.total_tokens);
  const totalSpendMicroUsd = Number(usage.total_spend_micro_usd);
  if (
    typeof usageDay !== 'string'
    || typeof dailyLimitReached !== 'boolean'
    || typeof resetsAt !== 'string'
    || !Number.isFinite(new Date(resetsAt).getTime())
    || ![
      dailyRequests, dailyTokens, dailySpendMicroUsd,
      totalRequests, totalTokens, totalSpendMicroUsd,
    ]
      .every((value) => Number.isSafeInteger(value) && value >= 0)
  ) {
    throw new EntitlementError('operational', 'Trial usage service returned an invalid response.');
  }

  const hasActiveProvider = Boolean(activeProvider?.provider);
  const trialActive = trialEndsAt.getTime() > now.getTime();
  const revoked = Boolean(parseDate(profile.lifetime_revoked_at));
  const paid = Boolean(lifetimePurchasedAt) && !revoked;
  const billingStatus: BillingState = paid ? 'paid' : revoked ? 'revoked' : trialActive ? 'trialing' : 'expired';
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
    canUseServerKey: !revoked && !hasActiveProvider && trialActive,
    requiresPurchase: revoked || (!paid && !trialActive),
    requiresProviderKey: paid && !trialActive && !hasActiveProvider,
    trialUsage: {
      usageDay,
      dailyRequests,
      dailyTokens,
      dailySpendMicroUsd,
      dailySpendLimitMicroUsd: config.trial.dailySpendMicroUsd,
      dailyLimitReached:
        dailyLimitReached || dailySpendMicroUsd >= config.trial.dailySpendMicroUsd,
      resetsAt,
      totalRequests,
      totalTokens,
      totalSpendMicroUsd,
    },
  };
}

/**
 * Create a server-owned checkout record before redirecting to Dodo. The webhook
 * can only grant an entitlement when a verified payment matches one of these
 * records for the authenticated user (product, amount, currency, unexpired).
 * Returns the record id so the caller can attach the Dodo session id afterwards.
 */
export type CheckoutReservation = {
  id: string;
  idempotencyKey: string;
  dodoSessionId: string | null;
  checkoutUrl: string | null;
  expiresAt: string;
};

export async function reserveCheckout(
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
): Promise<CheckoutReservation> {
  const { data, error } = await getAdminDb('webhook').rpc('danotch_reserve_checkout', {
    p_user_id: userId,
    p_product_id: productId,
    p_expected_amount: expectedAmount,
    p_expected_currency: expectedCurrency.toUpperCase(),
    p_expected_quantity: expectedQuantity,
    p_environment: environment,
  });

  if (error || !data) {
    throw new Error(`Failed to reserve checkout: ${error?.message ?? 'unknown error'}`);
  }
  const record = data as {
    id?: unknown;
    idempotency_key?: unknown;
    dodo_session_id?: unknown;
    checkout_url?: unknown;
    expires_at?: unknown;
  };
  if (
    typeof record.id !== 'string'
    || typeof record.idempotency_key !== 'string'
    || typeof record.expires_at !== 'string'
  ) {
    throw new Error('Failed to reserve checkout: invalid RPC response');
  }
  return {
    id: record.id,
    idempotencyKey: record.idempotency_key,
    dodoSessionId: typeof record.dodo_session_id === 'string' ? record.dodo_session_id : null,
    checkoutUrl: typeof record.checkout_url === 'string' ? record.checkout_url : null,
    expiresAt: record.expires_at,
  };
}

export async function attachCheckoutSession(params: {
  recordId: string;
  idempotencyKey: string;
  dodoSessionId: string;
  checkoutUrl: string;
}): Promise<boolean> {
  const { data, error } = await getAdminDb('webhook').rpc('danotch_attach_checkout_session', {
    p_checkout_record_id: params.recordId,
    p_idempotency_key: params.idempotencyKey,
    p_dodo_session_id: params.dodoSessionId,
    p_checkout_url: params.checkoutUrl,
  });
  if (error) {
    throw new Error(`Failed to attach checkout session: ${error.message}`);
  }
  return data === true;
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
  quantity: number;
  checkoutRecordId: string;
  dodoSessionId: string;
  environment: string;
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
    p_quantity: params.quantity,
    p_checkout_record_id: params.checkoutRecordId,
    p_dodo_session_id: params.dodoSessionId,
    p_environment: params.environment,
  });

  if (error) {
    throw new Error(`recordPayment RPC failed for payment ${params.paymentId}: ${error.message}`);
  }

  return (data as PaymentOutcome) ?? 'rejected';
}

export type PaymentReversalOutcome = 'revoked' | 'ignored' | 'duplicate';

export async function recordPaymentReversal(params: {
  deliveryId: string | null;
  eventType: 'refund.succeeded' | 'dispute.accepted' | 'dispute.lost';
  providerEventId: string;
  paymentId: string;
  amount: number | null;
  currency: string | null;
  reason: string | null;
}): Promise<PaymentReversalOutcome> {
  const { data, error } = await getAdminDb('webhook').rpc('danotch_record_payment_reversal', {
    p_delivery_id: params.deliveryId,
    p_event_type: params.eventType,
    p_provider_event_id: params.providerEventId,
    p_payment_id: params.paymentId,
    p_amount: params.amount,
    p_currency: params.currency?.toUpperCase() ?? null,
    p_is_full_refund: params.eventType === 'refund.succeeded',
    p_reason: params.reason,
  });
  if (error) {
    throw new Error(`recordPaymentReversal RPC failed for payment ${params.paymentId}: ${error.message}`);
  }
  return (data as PaymentReversalOutcome) ?? 'ignored';
}

export async function resolveProviderForUser(
  userId: string,
  modelOverride?: string,
  db: SupabaseClient = userDb,
  dependencies: {
    billingStatus?: typeof getBillingStatus;
    activeProvider?: typeof getActiveProviderForUser;
    fallbackProvider?: typeof getFallbackProvider;
    trialDb?: SupabaseClient;
  } = {},
): Promise<{ provider: LLMProvider; billingStatus: BillingStatus; source: 'byok' | 'trial_server_key' }> {
  const loadBillingStatus = dependencies.billingStatus ?? getBillingStatus;
  const loadActiveProvider = dependencies.activeProvider ?? getActiveProviderForUser;
  const loadFallbackProvider = dependencies.fallbackProvider ?? getFallbackProvider;
  const billingStatus = await loadBillingStatus(userId, db);

  if (billingStatus.requiresPurchase) {
    throw new EntitlementError(
      'trial_expired',
      'Your 14-day trial has ended. Buy Perch for $5 to continue, then add your own provider key.',
      billingStatus,
    );
  }

  let byokProvider: LLMProvider | null;
  try {
    byokProvider = await loadActiveProvider(userId, modelOverride);
  } catch (error) {
    if (error instanceof ProviderLookupError) {
      throw new EntitlementError(
        'operational',
        'Provider configuration is temporarily unavailable.',
        billingStatus,
      );
    }
    throw error;
  }

  if (byokProvider) {
    return { provider: byokProvider, billingStatus, source: 'byok' };
  }

  if (billingStatus.canUseServerKey) {
    let fallback: LLMProvider;
    try {
      fallback = loadFallbackProvider(modelOverride);
    } catch {
      throw new EntitlementError(
        'operational',
        'Server-funded trials are temporarily unavailable.',
        billingStatus,
      );
    }
    return {
      provider: new MeteredTrialProvider(userId, fallback, dependencies.trialDb),
      billingStatus,
      source: 'trial_server_key',
    };
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
