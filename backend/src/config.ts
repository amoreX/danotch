import { CHAT_SYSTEM_PROMPT } from './prompts.js';
import type { ProviderType } from './providers/types.js';

export const config = {
  port: parseInt(process.env.PORT || '3001', 10),
  notchWsUrl: process.env.NOTCH_WS_URL || 'ws://localhost:7778/ws',

  // Default API settings (used as fallback when no BYOK provider configured)
  api: {
    model: process.env.CLAUDE_MODEL || 'claude-sonnet-4-20250514',
    maxTokens: parseInt(process.env.MAX_TOKENS || '4096', 10),
    systemPrompt: CHAT_SYSTEM_PROMPT,
  },

  // Default models per provider (for BYOK)
  defaultModels: {
    anthropic: 'claude-sonnet-4-20250514',
    openai: 'gpt-4o',
    openrouter: 'anthropic/claude-sonnet-4-20250514',
  } as Record<ProviderType, string>,

  // Composio (Gmail integration)
  composio: {
    apiKey: process.env.COMPOSIO_API_KEY || '',
  },
} as const;
