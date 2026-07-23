import type { SupabaseClient } from '@supabase/supabase-js';
import { config } from '../config.js';
import { getAdminDb } from '../lib/admin-db.js';
import type {
  CanonicalMessage,
  CanonicalTool,
  CompletionResult,
  LLMProvider,
  StreamResult,
} from '../providers/types.js';

export type TrialLimitReason = 'daily_spend' | 'daily_tokens' | 'concurrency' | 'unavailable';

export class TrialLimitError extends Error {
  readonly code = 'trial_limit_exceeded';
  constructor(
    readonly reason: TrialLimitReason = 'unavailable',
    readonly retryAfterSeconds = 60,
    readonly resetAt: string | null = null,
  ) {
    super(
      reason === 'daily_spend' || reason === 'daily_tokens'
        ? 'Your $5 daily trial limit has been reached. Usage resumes automatically tomorrow.'
        : reason === 'concurrency'
          ? 'Too many trial requests are running. Try again shortly.'
          : 'Trial usage is temporarily unavailable. Try again shortly.',
    );
  }

  get isDailyLimit(): boolean {
    return this.reason === 'daily_spend' || this.reason === 'daily_tokens';
  }
}

export class MeteredTrialProvider implements LLMProvider {
  readonly providerName: string;
  readonly modelId: string;

  constructor(
    private readonly userId: string,
    private readonly provider: LLMProvider,
    private readonly db?: SupabaseClient,
  ) {
    this.providerName = provider.providerName;
    this.modelId = provider.modelId;
  }

  async stream(params: {
    messages: CanonicalMessage[];
    tools?: CanonicalTool[];
    systemPrompt: string;
    maxTokens: number;
    onText?: (text: string) => void;
  }): Promise<StreamResult> {
    return this.runMetered(params.messages, params.systemPrompt, params.tools, params.maxTokens, () =>
      this.provider.stream(params));
  }

  async complete(params: {
    messages: CanonicalMessage[];
    systemPrompt: string;
    maxTokens: number;
  }): Promise<CompletionResult> {
    return this.runMetered(params.messages, params.systemPrompt, undefined, params.maxTokens, () =>
      this.provider.complete(params));
  }

  private async runMetered<T extends { usage: { inputTokens: number; outputTokens: number } }>(
    messages: CanonicalMessage[],
    systemPrompt: string,
    tools: CanonicalTool[] | undefined,
    maxTokens: number,
    operation: () => Promise<T>,
  ): Promise<T> {
    const estimatedInputTokens = estimateInputTokens(messages, systemPrompt, tools);
    const db = this.db ?? getAdminDb('runner');
    const reservedTokens = estimatedInputTokens + maxTokens;
    const reservedSpend = estimatedInputTokens * config.trial.inputMicroUsdPerToken
      + maxTokens * config.trial.outputMicroUsdPerToken;
    const { data, error } = await db.rpc('danotch_reserve_trial_usage', {
      p_user_id: this.userId,
      p_reserved_tokens: reservedTokens,
      p_reserved_spend_micro_usd: reservedSpend,
      p_daily_token_limit: config.trial.dailyTokenLimit,
      p_daily_spend_micro_usd: config.trial.dailySpendMicroUsd,
      p_max_concurrency: config.trial.maxConcurrency,
    });
    if (error || !data) throw new TrialLimitError('unavailable');
    const reservation = data as {
      allowed?: boolean;
      lease_id?: string;
      reason?: unknown;
      retry_after_seconds?: number;
      reset_at?: unknown;
    };
    if (!reservation.allowed || !reservation.lease_id) {
      const reason: TrialLimitReason = (
        reservation.reason === 'daily_spend'
        || reservation.reason === 'daily_tokens'
        || reservation.reason === 'concurrency'
      ) ? reservation.reason : 'unavailable';
      const resetAt = typeof reservation.reset_at === 'string' ? reservation.reset_at : null;
      throw new TrialLimitError(
        reason,
        Math.max(1, Number(reservation.retry_after_seconds ?? 60)),
        resetAt,
      );
    }

    let actualInput = 0;
    let actualOutput = 0;
    try {
      const result = await operation();
      actualInput = result.usage.inputTokens;
      actualOutput = result.usage.outputTokens;
      return result;
    } finally {
      const actualSpend = actualInput * config.trial.inputMicroUsdPerToken
        + actualOutput * config.trial.outputMicroUsdPerToken;
      const settled = await db.rpc('danotch_settle_trial_usage', {
        p_lease_id: reservation.lease_id,
        p_user_id: this.userId,
        p_actual_tokens: actualInput + actualOutput,
        p_actual_spend_micro_usd: actualSpend,
      });
      if (settled.error) {
        console.error('[trial] Usage settlement failed');
      }
    }
  }
}

function estimateInputTokens(
  messages: CanonicalMessage[],
  systemPrompt: string,
  tools?: CanonicalTool[],
): number {
  const serialized = JSON.stringify({ messages, systemPrompt, tools: tools ?? [] });
  return Math.max(1, Math.ceil(Buffer.byteLength(serialized, 'utf8') / 3));
}
