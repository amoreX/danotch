import { homedir } from 'node:os';
import { join, resolve } from 'node:path';
import { CHAT_SYSTEM_PROMPT } from './prompts.js';

type Environment = Record<string, string | undefined>;

function integer(env: Environment, name: string, fallback: number, min: number, max: number): number {
  const value = Number(env[name] ?? fallback);
  if (!Number.isSafeInteger(value) || value < min || value > max) {
    throw new Error(`${name} must be an integer from ${min} to ${max}`);
  }
  return value;
}

export function loadConfig(env: Environment = process.env) {
  const root = resolve(env.PERCH_DATA_DIR || join(homedir(), 'Library', 'Application Support', 'Perch'));
  const allowedOrigin = env.PERCH_ALLOWED_ORIGIN ?? 'perch://app';
  if (allowedOrigin === '*' || !/^[a-z][a-z0-9+.-]*:\/\/[^,\s]+$/i.test(allowedOrigin)) {
    throw new Error('PERCH_ALLOWED_ORIGIN must be one exact non-wildcard origin');
  }

  return {
    protocolVersion: 1,
    host: '127.0.0.1',
    port: 0,
    dataDir: root,
    databasePath: join(root, 'data', 'perch.sqlite3'),
    discoveryPath: join(root, 'runtime', 'daemon.json'),
    allowedOrigin,
    jsonBodyLimit: integer(env, 'JSON_BODY_LIMIT_BYTES', 65_536, 1_024, 1_048_576),
    maxTokens: integer(env, 'MAX_TOKENS', 4_096, 128, 16_384),
    systemPrompt: CHAT_SYSTEM_PROMPT,
    sessionTtlMs: integer(env, 'SESSION_TTL_MS', 300_000, 30_000, 3_600_000),
    httpRateWindowMs: integer(env, 'HTTP_RATE_WINDOW_MS', 60_000, 1_000, 3_600_000),
    httpRateLimit: integer(env, 'HTTP_RATE_LIMIT', 240, 10, 10_000),
    wsMaxFrameBytes: integer(env, 'WS_MAX_FRAME_BYTES', 65_536, 1_024, 1_048_576),
    wsMaxMessagesPerWindow: integer(env, 'WS_MAX_MESSAGES_PER_WINDOW', 120, 10, 10_000),
    scheduler: {
      tickMs: integer(env, 'SCHEDULER_TICK_MS', 30_000, 1_000, 3_600_000),
      claimLimit: integer(env, 'SCHEDULER_CLAIM_LIMIT', 10, 1, 100),
      maxCatchUp: integer(env, 'SCHEDULER_MAX_CATCH_UP', 3, 0, 24),
      minIntervalMs: integer(env, 'SCHEDULER_MIN_INTERVAL_MS', 60_000, 10_000, 86_400_000),
      maxTokens: integer(env, 'SCHEDULER_MAX_TOKENS', 2_048, 128, 8_192),
    },
    drainDeadlineMs: integer(env, 'DRAIN_DEADLINE_MS', 10_000, 1_000, 60_000),
  } as const;
}

export type Config = ReturnType<typeof loadConfig>;
export const config = loadConfig();
