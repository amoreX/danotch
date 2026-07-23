import { getAdminDb } from '../lib/admin-db.js';
import { config } from '../config.js';
import { decrypt } from './crypto.js';
import { AnthropicProvider } from './anthropic.js';
import { OpenAIProvider } from './openai.js';
import type { LLMProvider, ProviderType } from './types.js';
import type { SupabaseClient } from '@supabase/supabase-js';

const OPENROUTER_BASE_URL = 'https://openrouter.ai/api/v1';
const supabase = new Proxy({} as ReturnType<typeof getAdminDb>, {
  get(_target, property) {
    const client = getAdminDb('provider') as unknown as Record<PropertyKey, unknown>;
    const value = client[property];
    return typeof value === 'function' ? value.bind(client) : value;
  },
});

export class ProviderLookupError extends Error {
  constructor(message: string, options?: ErrorOptions) {
    super(message, options);
    this.name = 'ProviderLookupError';
  }
}

function isNoRowsError(error: unknown): boolean {
  const postgrestError = error as { code?: string; details?: string } | null;
  return postgrestError?.code === 'PGRST116'
    && /\b0 rows?\b/i.test(postgrestError.details ?? '');
}

/**
 * Get the LLM provider for a specific user.
 * Checks for user's active provider config in DB, falls back to server's ANTHROPIC_API_KEY.
 */
export async function getProviderForUser(
  userId: string,
  fallbackModelId?: string,
  db: SupabaseClient = supabase,
): Promise<LLMProvider> {
  try {
    const { data, error } = await db
      .from('danotch_provider_configs')
      .select('provider, api_key_encrypted, model_id')
      .eq('user_id', userId)
      .eq('is_active', true)
      .single();

    if (error) {
      if (isNoRowsError(error)) return getFallbackProvider(fallbackModelId);
      throw new ProviderLookupError(`Provider lookup failed: ${error.message}`);
    }
    if (!data) throw new ProviderLookupError('Provider lookup returned no result');

    const apiKey = decrypt(data.api_key_encrypted);
    const modelId = fallbackModelId || data.model_id;
    console.log(`[provider] User ${userId} → ${data.provider} (${modelId})`);
    return createProvider(data.provider as ProviderType, apiKey, modelId);
  } catch (err) {
    if (err instanceof ProviderLookupError) throw err;
    throw new ProviderLookupError(`Provider config for user ${userId} could not be resolved`, {
      cause: err,
    });
  }
}

/**
 * Get only the user's active BYOK provider. Does not fall back to the server key.
 */
export async function getActiveProviderForUser(
  userId: string,
  modelOverride?: string,
  db: SupabaseClient = supabase,
): Promise<LLMProvider | null> {
  try {
    const { data, error } = await db
      .from('danotch_provider_configs')
      .select('provider, api_key_encrypted, model_id')
      .eq('user_id', userId)
      .eq('is_active', true)
      .single();

    if (error) {
      if (isNoRowsError(error)) return null;
      throw new ProviderLookupError(`Active provider lookup failed: ${error.message}`);
    }
    if (!data) throw new ProviderLookupError('Active provider lookup returned no result');

    const apiKey = decrypt(data.api_key_encrypted);
    const modelId = modelOverride || data.model_id;
    console.log(`[provider] User ${userId} BYOK → ${data.provider} (${modelId})`);
    return createProvider(data.provider as ProviderType, apiKey, modelId);
  } catch (err) {
    if (err instanceof ProviderLookupError) throw err;
    throw new ProviderLookupError(`Active provider for user ${userId} could not be resolved`, {
      cause: err,
    });
  }
}

/**
 * Fallback provider using the server's ANTHROPIC_API_KEY env var.
 * Used when user has no provider config or for unauthenticated requests.
 */
export function getFallbackProvider(modelId?: string): LLMProvider {
  if (!config.containment.trialsEnabled || !config.trial.apiKey) {
    throw new ProviderLookupError('Server-funded trials are not configured');
  }
  const selectedModel = modelId ?? config.trial.defaultModel;
  if (!config.trial.allowedModels.includes(selectedModel)) {
    throw new ProviderLookupError('Requested model is not available for server-funded trials');
  }
  return new AnthropicProvider(
    config.trial.apiKey,
    selectedModel,
  );
}

/**
 * Create a provider instance from explicit config. Used by verify endpoint and factory.
 */
export function createProvider(
  provider: ProviderType,
  apiKey: string,
  modelId: string
): LLMProvider {
  switch (provider) {
    case 'anthropic':
      return new AnthropicProvider(apiKey, modelId);
    case 'openai':
      return new OpenAIProvider(apiKey, modelId);
    case 'openrouter':
      return new OpenAIProvider(apiKey, modelId, OPENROUTER_BASE_URL);
    default:
      throw new Error(`Unsupported provider: ${provider}`);
  }
}
