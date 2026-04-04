export const config = {
  port: parseInt(process.env.PORT || '3001', 10),
  notchWsUrl: process.env.NOTCH_WS_URL || 'ws://localhost:7778/ws',

  // Claude Agent SDK options
  agent: {
    model: process.env.CLAUDE_MODEL || 'claude-sonnet-4-20250514',
    maxTurns: parseInt(process.env.MAX_TURNS || '10', 10),
    systemPrompt: `You are a helpful assistant running inside Danotch, a macOS notch overlay app.
Keep responses concise and actionable. You have access to Claude Code tools (Bash, Read, Write, Edit, Grep, Glob, etc.) to help users with their tasks.`,
    permissionMode: 'acceptEdits' as const,
  },

  // Anthropic API (for direct API calls without agent tools)
  api: {
    model: process.env.CLAUDE_API_MODEL || 'claude-sonnet-4-20250514',
    maxTokens: parseInt(process.env.MAX_TOKENS || '4096', 10),
  },
} as const;
