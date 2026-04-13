import { supabase } from '../lib/supabase.js';
import { config } from '../config.js';
import { decrypt } from './crypto.js';
import { AnthropicProvider } from './anthropic.js';
import { OpenAIProvider } from './openai.js';
import type { LLMProvider, ProviderType } from './types.js';

const OPENROUTER_BASE_URL = 'https://openrouter.ai/api/v1';

/**
 * Get the LLM provider for a specific user.
 * Checks for user's active provider config in DB, falls back to server's ANTHROPIC_API_KEY.
 */
export async function getProviderForUser(userId: string): Promise<LLMProvider> {
  try {
    const { data, error } = await supabase
      .from('provider_configs')
      .select('provider, api_key_encrypted, model_id')
      .eq('user_id', userId)
      .eq('is_active', true)
      .single();

    if (!error && data) {
      const apiKey = decrypt(data.api_key_encrypted);
      console.log(`[provider] User ${userId} → ${data.provider} (${data.model_id})`);
      return createProvider(data.provider as ProviderType, apiKey, data.model_id);
    }
  } catch (err) {
    console.warn(`[provider] Failed to load config for user ${userId}, using fallback:`, err);
  }

  return getFallbackProvider();
}

/**
 * Fallback provider using the server's ANTHROPIC_API_KEY env var.
 * Used when user has no provider config or for unauthenticated requests.
 */
export function getFallbackProvider(): LLMProvider {
  return new AnthropicProvider(
    process.env.ANTHROPIC_API_KEY ?? '',
    config.api.model
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
