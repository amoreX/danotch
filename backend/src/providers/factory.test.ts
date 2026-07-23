import assert from 'node:assert/strict';
import { test } from 'node:test';
import type { SupabaseClient } from '@supabase/supabase-js';

process.env.SUPABASE_URL = 'https://test.supabase.co';
process.env.SUPABASE_PUBLISHABLE_KEY = 'test-publishable-key';
process.env.TRIALS_ENABLED = 'true';
process.env.TRIAL_ANTHROPIC_API_KEY = 'test-trial-key';
process.env.TRIAL_ANTHROPIC_MODELS = 'claude-sonnet-4-6';

const {
  ProviderLookupError,
  getActiveProviderForUser,
  getProviderForUser,
} = await import('./factory.ts');

function providerDb(result: {
  data: Record<string, unknown> | null;
  error: { code?: string; message: string; details?: string } | null;
}): SupabaseClient {
  return {
    from() {
      const builder = {
        select() {
          return builder;
        },
        eq() {
          return builder;
        },
        async single() {
          return result;
        },
      };
      return builder;
    },
  } as unknown as SupabaseClient;
}

test('missing active provider is the only lookup outcome that permits fallback', async () => {
  const missing = providerDb({
    data: null,
    error: {
      code: 'PGRST116',
      message: 'JSON object requested, multiple (or no) rows returned',
      details: 'The result contains 0 rows',
    },
  });

  assert.equal(await getActiveProviderForUser('user-a', undefined, missing), null);
  const fallback = await getProviderForUser('user-a', undefined, missing);
  assert.equal(fallback.providerName, 'anthropic');
});

test('provider database errors fail closed instead of becoming no-key or fallback outcomes', async () => {
  const unavailable = providerDb({
    data: null,
    error: { code: '08006', message: 'connection failure' },
  });

  await assert.rejects(
    getActiveProviderForUser('user-a', undefined, unavailable),
    ProviderLookupError,
  );
  await assert.rejects(
    getProviderForUser('user-a', undefined, unavailable),
    ProviderLookupError,
  );
});

test('ambiguous single-row responses fail closed instead of permitting fallback', async () => {
  const ambiguous = providerDb({
    data: null,
    error: {
      code: 'PGRST116',
      message: 'JSON object requested, multiple (or no) rows returned',
      details: 'The result contains 2 rows',
    },
  });

  await assert.rejects(
    getProviderForUser('user-a', undefined, ambiguous),
    ProviderLookupError,
  );
});

test('corrupt active provider records fail closed', async () => {
  const corrupt = providerDb({
    data: { provider: 'anthropic', api_key_encrypted: 'not-ciphertext', model_id: 'model' },
    error: null,
  });

  await assert.rejects(
    getActiveProviderForUser('user-a', undefined, corrupt),
    ProviderLookupError,
  );
});
