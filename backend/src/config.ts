import { CHAT_SYSTEM_PROMPT } from './prompts.js';
import type { ProviderType } from './providers/types.js';

export const config = {
  port: parseInt(process.env.PORT || '3001', 10),
  notchWsUrl: process.env.NOTCH_WS_URL || 'ws://localhost:7778/ws',

  // Default API settings (used as fallback when no BYOK provider configured)
  api: {
    model: process.env.CLAUDE_MODEL || 'claude-sonnet-4-6',
    maxTokens: parseInt(process.env.MAX_TOKENS || '4096', 10),
    systemPrompt: CHAT_SYSTEM_PROMPT,
  },

  // Default models per provider (for BYOK)
  defaultModels: {
    anthropic: 'claude-sonnet-4-6',
    openai: 'gpt-5',
    openrouter: 'anthropic/claude-sonnet-4-6',
  } as Record<ProviderType, string>,

  // Composio (Gmail integration)
  composio: {
    apiKey: process.env.COMPOSIO_API_KEY || '',
  },

  // Dodo Payments (one-time purchase unlock)
  dodo: {
    apiKey: process.env.DODO_PAYMENTS_API_KEY || '',
    webhookKey: process.env.DODO_PAYMENTS_WEBHOOK_KEY || '',
    productId: process.env.DODO_PAYMENTS_PRODUCT_ID || '',
    returnUrl: process.env.DODO_PAYMENTS_RETURN_URL || '',
    environment: process.env.DODO_PAYMENTS_ENVIRONMENT || 'test_mode',
    // Expected commercial contract. A verified payment must match these exactly
    // (in addition to the product id) before it grants an entitlement. Amount is
    // in the currency's minor units (e.g. cents). Quantity defaults to 1.
    expectedAmount: parseInt(process.env.DODO_PAYMENTS_EXPECTED_AMOUNT || '500', 10),
    expectedCurrency: (process.env.DODO_PAYMENTS_EXPECTED_CURRENCY || 'USD').toUpperCase(),
    expectedQuantity: parseInt(process.env.DODO_PAYMENTS_EXPECTED_QUANTITY || '1', 10),
  },
} as const;
