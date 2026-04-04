import { CHAT_SYSTEM_PROMPT, AGENT_SYSTEM_PROMPT } from './prompts.js';

export const config = {
  port: parseInt(process.env.PORT || '3001', 10),
  notchWsUrl: process.env.NOTCH_WS_URL || 'ws://localhost:7778/ws',

  // Claude Agent SDK options
  agent: {
    model: process.env.CLAUDE_MODEL || 'claude-sonnet-4-20250514',
    maxTurns: parseInt(process.env.MAX_TURNS || '10', 10),
    systemPrompt: AGENT_SYSTEM_PROMPT,
    permissionMode: 'acceptEdits' as const,
  },

  // Anthropic API (for direct API calls without agent tools)
  api: {
    model: process.env.CLAUDE_API_MODEL || 'claude-sonnet-4-20250514',
    maxTokens: parseInt(process.env.MAX_TOKENS || '4096', 10),
    systemPrompt: CHAT_SYSTEM_PROMPT,
  },
} as const;
