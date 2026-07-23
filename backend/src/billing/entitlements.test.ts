import assert from 'node:assert/strict';
import { test } from 'node:test';
import type { SupabaseClient } from '@supabase/supabase-js';
import type { LLMProvider } from '../providers/types.ts';
import type { BillingStatus } from './entitlements.ts';

process.env.SUPABASE_URL = 'https://test.supabase.co';
process.env.SUPABASE_PUBLISHABLE_KEY = 'test-publishable-key';

const { ProviderLookupError } = await import('../providers/factory.ts');
const {
  EntitlementError,
  getBillingStatus,
  resolveProviderForUser,
} = await import('./entitlements.ts');

const USER_ID = '10000000-0000-4000-8000-000000000001';

function provider(name: string): LLMProvider {
  return {
    providerName: name,
    modelId: `${name}-model`,
    async stream() {
      throw new Error('not called');
    },
    async complete() {
      throw new Error('not called');
    },
  };
}

function status(
  billingStatus: BillingStatus['billingStatus'],
  hasActiveProvider: boolean,
): BillingStatus {
  const trialing = billingStatus === 'trialing';
  const paid = billingStatus === 'paid';
  return {
    userId: USER_ID,
    billingStatus,
    trialStartedAt: '2026-07-01T00:00:00.000Z',
    trialEndsAt: trialing ? '2099-07-15T00:00:00.000Z' : '2026-07-15T00:00:00.000Z',
    trialDaysRemaining: trialing ? 14 : 0,
    lifetimePurchasedAt: paid ? '2026-07-10T00:00:00.000Z' : null,
    hasActiveProvider,
    activeProvider: hasActiveProvider ? 'anthropic' : null,
    canUseServerKey: trialing && !hasActiveProvider,
    requiresPurchase: billingStatus === 'expired',
    requiresProviderKey: paid && !hasActiveProvider,
    trialUsage: {
      usageDay: '2026-07-10',
      dailyRequests: 2,
      dailyTokens: 1200,
      dailySpendMicroUsd: 25_000,
      dailySpendLimitMicroUsd: 5_000_000,
      dailyLimitReached: false,
      resetsAt: '2026-07-11T00:00:00.000Z',
      totalRequests: 8,
      totalTokens: 5000,
      totalSpendMicroUsd: 100_000,
    },
  };
}

async function resolve(
  billingStatus: BillingStatus,
  activeProvider: LLMProvider | null,
) {
  let providerLookups = 0;
  const result = await resolveProviderForUser(
    USER_ID,
    undefined,
    {} as SupabaseClient,
    {
      billingStatus: async () => billingStatus,
      activeProvider: async () => {
        providerLookups += 1;
        return activeProvider;
      },
      fallbackProvider: () => provider('server'),
    },
  );
  return { result, providerLookups };
}

test('trial and lifetime entitlements resolve BYOK, while an active trial may use the server key', async () => {
  const trialByok = await resolve(status('trialing', true), provider('byok'));
  assert.equal(trialByok.result.source, 'byok');
  assert.equal(trialByok.providerLookups, 1);

  const trialServer = await resolve(status('trialing', false), null);
  assert.equal(trialServer.result.source, 'trial_server_key');
  assert.equal(trialServer.providerLookups, 1);

  const paidByok = await resolve(status('paid', true), provider('byok'));
  assert.equal(paidByok.result.source, 'byok');
  assert.equal(paidByok.providerLookups, 1);
});

test('lifetime users without BYOK receive provider_key_required', async () => {
  await assert.rejects(
    resolve(status('paid', false), null),
    (error: unknown) =>
      error instanceof EntitlementError && error.code === 'provider_key_required',
  );
});

test('expired users are rejected before BYOK lookup even when a key is active', async () => {
  for (const hasByok of [false, true]) {
    let providerLookups = 0;
    await assert.rejects(
      resolveProviderForUser(
        USER_ID,
        undefined,
        {} as SupabaseClient,
        {
          billingStatus: async () => status('expired', hasByok),
          activeProvider: async () => {
            providerLookups += 1;
            return hasByok ? provider('byok') : null;
          },
        },
      ),
      (error: unknown) =>
        error instanceof EntitlementError && error.code === 'trial_expired',
    );
    assert.equal(providerLookups, 0);
  }
});

test('provider lookup failures fail closed as operational entitlement errors', async () => {
  await assert.rejects(
    resolveProviderForUser(
      USER_ID,
      undefined,
      {} as SupabaseClient,
      {
        billingStatus: async () => status('trialing', true),
        activeProvider: async () => {
          throw new ProviderLookupError('database unavailable');
        },
      },
    ),
    (error: unknown) =>
      error instanceof EntitlementError && error.code === 'operational',
  );
});

function fakeBillingDb(options: {
  profile: Record<string, unknown>;
  activeProvider?: string | null;
  providerError?: { message: string; code?: string } | null;
  usage?: Record<string, unknown>;
  usageError?: { message: string; code?: string } | null;
}): SupabaseClient {
  return {
    from(table: string) {
      const builder = {
        select() {
          return builder;
        },
        eq() {
          return builder;
        },
        async single() {
          assert.equal(table, 'danotch_user_profiles');
          return { data: options.profile, error: null };
        },
        async maybeSingle() {
          assert.equal(table, 'danotch_provider_configs');
          return {
            data: options.activeProvider ? { provider: options.activeProvider } : null,
            error: options.providerError ?? null,
          };
        },
      };
      return builder;
    },
    async rpc(name: string) {
      assert.equal(name, 'danotch_get_trial_usage_summary');
      return {
        data: options.usage ?? {
          usage_day: '2026-07-10',
          daily_requests: 2,
          daily_tokens: 1200,
          daily_spend_micro_usd: 25_000,
          daily_limit_reached: false,
          resets_at: '2026-07-11T00:00:00.000Z',
          total_requests: 8,
          total_tokens: 5000,
          total_spend_micro_usd: 100_000,
        },
        error: options.usageError ?? null,
      };
    },
  } as unknown as SupabaseClient;
}

test('billing status requires a lifetime timestamp and fails closed on provider status errors', async () => {
  const expired = await getBillingStatus(USER_ID, fakeBillingDb({
    profile: {
      id: USER_ID,
      trial_started_at: '2026-06-01T00:00:00.000Z',
      trial_ends_at: '2026-06-15T00:00:00.000Z',
      lifetime_purchased_at: null,
      billing_status: 'paid',
    },
  }));
  assert.equal(expired.billingStatus, 'expired');
  assert.equal(expired.requiresPurchase, true);
  assert.equal(expired.trialUsage.dailySpendLimitMicroUsd, 5_000_000);
  assert.equal(expired.trialUsage.totalSpendMicroUsd, 100_000);

  const revoked = await getBillingStatus(USER_ID, fakeBillingDb({
    profile: {
      id: USER_ID,
      trial_started_at: '2026-06-01T00:00:00.000Z',
      trial_ends_at: '2099-06-15T00:00:00.000Z',
      lifetime_purchased_at: '2026-06-10T00:00:00.000Z',
      lifetime_revoked_at: '2026-06-11T00:00:00.000Z',
      billing_status: 'revoked',
    },
  }));
  assert.equal(revoked.billingStatus, 'revoked');
  assert.equal(revoked.requiresPurchase, true);
  assert.equal(revoked.canUseServerKey, false);

  await assert.rejects(
    getBillingStatus(USER_ID, fakeBillingDb({
      profile: {
        id: USER_ID,
        trial_started_at: '2026-06-01T00:00:00.000Z',
        trial_ends_at: '2099-06-15T00:00:00.000Z',
        lifetime_purchased_at: null,
        billing_status: 'trialing',
      },
      providerError: { message: 'connection refused' },
    })),
    (error: unknown) =>
      error instanceof EntitlementError && error.code === 'operational',
  );
});

test('billing status fails closed when the account usage ledger is unavailable', async () => {
  await assert.rejects(
    getBillingStatus(USER_ID, fakeBillingDb({
      profile: {
        id: USER_ID,
        trial_started_at: '2026-06-01T00:00:00.000Z',
        trial_ends_at: '2099-06-15T00:00:00.000Z',
        lifetime_purchased_at: null,
        billing_status: 'trialing',
      },
      usageError: { message: 'ledger unavailable' },
    })),
    (error: unknown) =>
      error instanceof EntitlementError && error.code === 'operational',
  );
});
