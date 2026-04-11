import { CHAT_SYSTEM_PROMPT } from './prompts.js';

export const config = {
  port: parseInt(process.env.PORT || '3001', 10),
  notchWsUrl: process.env.NOTCH_WS_URL || 'ws://localhost:7778/ws',

  // Anthropic API
  api: {
    model: process.env.CLAUDE_MODEL || 'claude-sonnet-4-20250514',
    maxTokens: parseInt(process.env.MAX_TOKENS || '4096', 10),
    systemPrompt: CHAT_SYSTEM_PROMPT,
  },

  // Composio (Gmail integration)
  composio: {
    apiKey: process.env.COMPOSIO_API_KEY || '',
  },
} as const;
