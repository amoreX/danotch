import assert from 'node:assert/strict';
import { test } from 'node:test';
import type { SupabaseClient } from '@supabase/supabase-js';
import type { LLMProvider } from '../providers/types.ts';

process.env.TRIALS_ENABLED = 'true';
process.env.TRIAL_ANTHROPIC_API_KEY = 'test-key';
process.env.SUPABASE_URL = 'https://test.supabase.co';
process.env.SUPABASE_PUBLISHABLE_KEY = 'test-publishable-key';

const { MeteredTrialProvider, TrialLimitError } = await import('./trial-provider.ts');

test('trial provider reserves before use and settles actual token and spend usage', async () => {
  const calls: { name: string; args: Record<string, unknown> }[] = [];
  const db = {
    async rpc(name: string, args: Record<string, unknown>) {
      calls.push({ name, args });
      return name === 'danotch_reserve_trial_usage'
        ? { data: { allowed: true, lease_id: 'lease-1' }, error: null }
        : { data: true, error: null };
    },
  } as unknown as SupabaseClient;
  const provider: LLMProvider = {
    providerName: 'anthropic',
    modelId: 'allowed',
    async stream() {
      return {
        content: [{ type: 'text', text: 'ok' }],
        stopReason: 'end_turn',
        usage: { inputTokens: 100, outputTokens: 20 },
      };
    },
    async complete() {
      return { text: 'ok', usage: { inputTokens: 100, outputTokens: 20 } };
    },
  };
  const metered = new MeteredTrialProvider('user-1', provider, db);
  await metered.complete({
    messages: [{ role: 'user', content: 'hello' }],
    systemPrompt: 'safe',
    maxTokens: 100,
  });
  assert.equal(calls[0].name, 'danotch_reserve_trial_usage');
  assert.equal(calls[1].name, 'danotch_settle_trial_usage');
  assert.equal(calls[1].args.p_actual_tokens, 120);
  assert.equal(calls[1].args.p_actual_spend_micro_usd, 600);
});

test('trial provider fails closed when reservation is denied', async () => {
  const db = {
    async rpc() {
      return { data: { allowed: false, retry_after_seconds: 90 }, error: null };
    },
  } as unknown as SupabaseClient;
  const provider = {
    providerName: 'anthropic',
    modelId: 'allowed',
  } as LLMProvider;
  const metered = new MeteredTrialProvider('user-1', provider, db);
  await assert.rejects(
    metered.complete({ messages: [], systemPrompt: '', maxTokens: 10 }),
    (error: unknown) => error instanceof TrialLimitError && error.retryAfterSeconds === 90,
  );
});
