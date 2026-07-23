import { CHAT_SYSTEM_PROMPT } from './prompts.js';
import type { ProviderType } from './providers/types.js';

export const containmentFeatureEnabled = (production: boolean, value: string | undefined) =>
  value === 'true' || (!production && value !== 'false');

type Environment = Record<string, string | undefined>;

function positiveInteger(
  env: Environment,
  name: string,
  developmentDefault: number,
  production: boolean,
): number {
  const raw = env[name];
  if (production && raw === undefined) throw new Error(`Missing production configuration: ${name}`);
  const value = Number(raw ?? developmentDefault);
  if (!Number.isSafeInteger(value) || value <= 0) {
    throw new Error(`${name} must be a positive integer`);
  }
  return value;
}

function boundedPositiveInteger(
  env: Environment,
  name: string,
  developmentDefault: number,
  production: boolean,
  maximum: number,
  minimum = 1,
): number {
  const value = positiveInteger(env, name, developmentDefault, production);
  if (value < minimum) throw new Error(`${name} must be at least ${minimum}`);
  if (value > maximum) throw new Error(`${name} must be at most ${maximum}`);
  return value;
}

function secureUrl(value: string, name: string, protocol: 'https:' | 'wss:'): string {
  let parsed: URL;
  try {
    parsed = new URL(value);
  } catch {
    throw new Error(`${name} must be a valid ${protocol.slice(0, -1).toUpperCase()} URL`);
  }
  if (parsed.protocol !== protocol || parsed.username || parsed.password || parsed.hash) {
    throw new Error(`${name} must be a credential-free ${protocol.slice(0, -1).toUpperCase()} URL`);
  }
  if (['localhost', '127.0.0.1', '::1'].includes(parsed.hostname)) {
    throw new Error(`${name} must not use localhost in production`);
  }
  return parsed.toString().replace(/\/$/, '');
}

export function loadConfig(env: Environment = process.env) {
  const isProduction = env.NODE_ENV === 'production';
  const port = positiveInteger(env, 'PORT', 3001, false);
  const publicBaseUrl = isProduction
    ? secureUrl(env.PUBLIC_BASE_URL ?? '', 'PUBLIC_BASE_URL', 'https:')
    : env.PUBLIC_BASE_URL ?? `http://localhost:${port}`;
  const gatewayPublicUrl = isProduction
    ? secureUrl(env.DEVICE_GATEWAY_URL ?? '', 'DEVICE_GATEWAY_URL', 'wss:')
    : env.DEVICE_GATEWAY_URL ?? `ws://localhost:${port}/api/device-gateway`;
  const notchWsUrl = isProduction
    ? (env.NOTCH_WS_URL ? secureUrl(env.NOTCH_WS_URL, 'NOTCH_WS_URL', 'wss:') : '')
    : env.NOTCH_WS_URL ?? 'ws://localhost:7778/ws';
  const signingSecret = env.DEVICE_TICKET_SIGNING_SECRET
    ?? (isProduction ? '' : 'development-device-ticket-secret-change-me');
  if (Buffer.byteLength(signingSecret) < 32) {
    throw new Error('DEVICE_TICKET_SIGNING_SECRET must be at least 32 bytes');
  }
  const trustProxyRaw = env.TRUST_PROXY;
  if (isProduction && trustProxyRaw === undefined) {
    throw new Error('Missing production configuration: TRUST_PROXY');
  }
  const trustProxy = trustProxyRaw === undefined ? false : Number(trustProxyRaw);
  if (trustProxy !== false && (!Number.isSafeInteger(trustProxy) || trustProxy < 1 || trustProxy > 10)) {
    throw new Error('TRUST_PROXY must be an explicit proxy hop count from 1 to 10');
  }
  const allowedOrigins = (env.DEVICE_ALLOWED_ORIGINS ?? (isProduction ? '' : 'perch://app'))
    .split(',')
    .map((origin) => origin.trim())
    .filter(Boolean);
  if (allowedOrigins.length === 0 || allowedOrigins.some((origin) => origin === '*' || origin.includes(','))) {
    throw new Error('DEVICE_ALLOWED_ORIGINS must contain exact origins and cannot use a wildcard');
  }
  const replayPageSize = positiveInteger(env, 'DEVICE_REPLAY_PAGE_SIZE', 100, isProduction);
  if (replayPageSize > 500) throw new Error('DEVICE_REPLAY_PAGE_SIZE must be at most 500');
  const captchaProvider = env.CAPTCHA_PROVIDER ?? (isProduction ? '' : 'turnstile');
  if (captchaProvider !== 'turnstile' && captchaProvider !== 'hcaptcha') {
    throw new Error('CAPTCHA_PROVIDER must be turnstile or hcaptcha');
  }
  const captchaSecret = env.CAPTCHA_SECRET ?? '';
  const captchaSiteKey = env.CAPTCHA_SITE_KEY ?? '';
  const captchaExpectedHostname = env.CAPTCHA_EXPECTED_HOSTNAME ?? '';
  if (isProduction && (!captchaSecret || !captchaSiteKey || !captchaExpectedHostname)) {
    throw new Error(
      'CAPTCHA_SECRET, CAPTCHA_SITE_KEY, and CAPTCHA_EXPECTED_HOSTNAME are required in production',
    );
  }
  const publicSignupEnabled = containmentFeatureEnabled(isProduction, env.PUBLIC_SIGNUP_ENABLED);
  const trialsEnabled = env.TRIALS_ENABLED === 'true';
  const costlyIntegrationsEnabled = containmentFeatureEnabled(
    isProduction,
    env.COSTLY_INTEGRATIONS_ENABLED,
  );
  const composioAuthConfigIds = {
    gmail: env.COMPOSIO_AUTH_CONFIG_GMAIL ?? '',
    googlecalendar: env.COMPOSIO_AUTH_CONFIG_GOOGLECALENDAR ?? '',
    googledocs: env.COMPOSIO_AUTH_CONFIG_GOOGLEDOCS ?? '',
    github: env.COMPOSIO_AUTH_CONFIG_GITHUB ?? '',
  };
  if (
    isProduction
    && costlyIntegrationsEnabled
    && Object.values(composioAuthConfigIds).some((value) => !value)
  ) {
    throw new Error('Pinned COMPOSIO_AUTH_CONFIG_* identifiers are required');
  }
  const trialApiKey = env.TRIAL_ANTHROPIC_API_KEY ?? '';
  if (trialsEnabled && !trialApiKey) {
    throw new Error('TRIAL_ANTHROPIC_API_KEY is required when TRIALS_ENABLED is true');
  }
  const trialModels = (env.TRIAL_ANTHROPIC_MODELS ?? 'claude-sonnet-4-6')
    .split(',')
    .map((model) => model.trim())
    .filter(Boolean);
  if (trialsEnabled && (trialModels.length === 0 || trialModels.some((model) => !/^[a-zA-Z0-9._-]{1,100}$/.test(model)))) {
    throw new Error('TRIAL_ANTHROPIC_MODELS must be a non-empty comma-separated model allowlist');
  }
  const trialDefaultModel = env.TRIAL_ANTHROPIC_MODEL ?? trialModels[0] ?? '';
  if (trialsEnabled && !trialModels.includes(trialDefaultModel)) {
    throw new Error('TRIAL_ANTHROPIC_MODEL must appear in TRIAL_ANTHROPIC_MODELS');
  }

  // PROVIDER_KEY_SECRET is required in production. In development the crypto
  // module throws lazily, but we validate eagerly here so startup fails closed.
  const providerKeySecret = env.PROVIDER_KEY_SECRET ?? '';
  if (isProduction && providerKeySecret.length < 32) {
    throw new Error(
      'PROVIDER_KEY_SECRET must be at least 32 characters in production. '
      + 'Generate a long random secret and add it to your environment.',
    );
  }

  const dodoEnvironment = env.DODO_PAYMENTS_ENVIRONMENT ?? (isProduction ? '' : 'test_mode');
  if (dodoEnvironment !== 'test_mode' && dodoEnvironment !== 'live_mode') {
    throw new Error('DODO_PAYMENTS_ENVIRONMENT must be test_mode or live_mode');
  }
  const dodoApiKey = env.DODO_PAYMENTS_API_KEY ?? '';
  const dodoWebhookKey = env.DODO_PAYMENTS_WEBHOOK_KEY ?? '';
  const dodoProductId = env.DODO_PAYMENTS_PRODUCT_ID ?? '';
  const dodoReturnUrl = env.DODO_PAYMENTS_RETURN_URL ?? '';
  const dodoExpectedAmount = positiveInteger(
    env,
    'DODO_PAYMENTS_EXPECTED_AMOUNT',
    500,
    isProduction,
  );
  const dodoExpectedQuantity = positiveInteger(
    env,
    'DODO_PAYMENTS_EXPECTED_QUANTITY',
    1,
    isProduction,
  );
  const dodoExpectedCurrency = (env.DODO_PAYMENTS_EXPECTED_CURRENCY ?? 'USD').toUpperCase();
  if (!/^[A-Z]{3}$/.test(dodoExpectedCurrency)) {
    throw new Error('DODO_PAYMENTS_EXPECTED_CURRENCY must be a three-letter ISO currency code');
  }
  if (isProduction) {
    if (dodoEnvironment !== 'live_mode') {
      throw new Error('DODO_PAYMENTS_ENVIRONMENT must be live_mode in production');
    }
    const missing = [
      ['DODO_PAYMENTS_API_KEY', dodoApiKey],
      ['DODO_PAYMENTS_WEBHOOK_KEY', dodoWebhookKey],
      ['DODO_PAYMENTS_PRODUCT_ID', dodoProductId],
      ['DODO_PAYMENTS_RETURN_URL', dodoReturnUrl],
    ].filter(([, value]) => !value).map(([name]) => name);
    if (missing.length > 0) {
      throw new Error(`Missing production Dodo configuration: ${missing.join(', ')}`);
    }
    const returnUrl = secureUrl(dodoReturnUrl, 'DODO_PAYMENTS_RETURN_URL', 'https:');
    const expectedReturnUrl = `${publicBaseUrl}/api/billing/return`;
    if (returnUrl !== expectedReturnUrl) {
      throw new Error(`DODO_PAYMENTS_RETURN_URL must equal ${expectedReturnUrl}`);
    }
  }

  return {
    isProduction,
    port,
    trustProxy,
    providerKeySecret,
    jsonBodyLimit: positiveInteger(env, 'JSON_BODY_LIMIT_BYTES', 64 * 1024, isProduction),
    notchWsUrl,
    publicBaseUrl,
    captcha: {
      provider: captchaProvider,
      secret: captchaSecret,
      siteKey: captchaSiteKey,
      expectedHostname: captchaExpectedHostname || undefined,
    },
    signup: {
      blockedDomains: new Set(
        (env.SIGNUP_BLOCKED_DOMAINS ?? '')
          .split(',')
          .map((domain) => domain.trim().toLowerCase())
          .filter(Boolean),
      ),
    },
    oauth: {
      stateTtlMs: positiveInteger(env, 'OAUTH_STATE_TTL_MS', 10 * 60_000, isProduction),
    },
    authRateLimit: {
      windowMs: boundedPositiveInteger(env, 'AUTH_RATE_WINDOW_MS', 15 * 60_000, isProduction, 86_400_000),
      login: boundedPositiveInteger(env, 'AUTH_LOGIN_RATE_LIMIT', 10, isProduction, 1000),
      refresh: boundedPositiveInteger(env, 'AUTH_REFRESH_RATE_LIMIT', 30, isProduction, 5000),
    },
    containment: {
      publicSignupEnabled,
      costlyIntegrationsEnabled,
      trialsEnabled,
    },
    deviceGateway: {
      publicUrl: gatewayPublicUrl,
      path: '/api/device-gateway',
      signingSecret,
      allowedOrigins,
      freshAuthMaxAgeMs: positiveInteger(env, 'DEVICE_FRESH_AUTH_MAX_AGE_MS', 5 * 60_000, isProduction),
      challengeTtlMs: positiveInteger(env, 'DEVICE_CHALLENGE_TTL_MS', 60_000, isProduction),
      ticketTtlMs: positiveInteger(env, 'DEVICE_TICKET_TTL_MS', 30_000, isProduction),
      maxDevicesPerUser: positiveInteger(env, 'DEVICE_MAX_PER_USER', 3, isProduction),
      supportedProtocolVersions: [1] as const,
      maxPayloadBytes: positiveInteger(env, 'DEVICE_MAX_PAYLOAD_BYTES', 64 * 1024, isProduction),
      maxMessagesPerWindow: positiveInteger(env, 'DEVICE_MAX_MESSAGES_PER_WINDOW', 120, isProduction),
      maxBytesPerWindow: positiveInteger(env, 'DEVICE_MAX_BYTES_PER_WINDOW', 512 * 1024, isProduction),
      rateWindowMs: positiveInteger(env, 'DEVICE_RATE_WINDOW_MS', 60_000, isProduction),
      maxConnectionBytes: positiveInteger(env, 'DEVICE_MAX_CONNECTION_BYTES', 16 * 1024 * 1024, isProduction),
      maxBufferedBytes: positiveInteger(env, 'DEVICE_MAX_BUFFERED_BYTES', 256 * 1024, isProduction),
      heartbeatIntervalMs: positiveInteger(env, 'DEVICE_HEARTBEAT_INTERVAL_MS', 20_000, isProduction),
      heartbeatTimeoutMs: positiveInteger(env, 'DEVICE_HEARTBEAT_TIMEOUT_MS', 60_000, isProduction),
      handshakeTimeoutMs: positiveInteger(env, 'DEVICE_HANDSHAKE_TIMEOUT_MS', 5_000, isProduction),
      replayPageSize,
      waitingExpirySweepMs: positiveInteger(
        env,
        'DEVICE_WAITING_EXPIRY_SWEEP_MS',
        30_000,
        isProduction,
      ),
    },
    api: {
      model: trialDefaultModel || 'claude-sonnet-4-6',
      maxTokens: boundedPositiveInteger(env, 'MAX_TOKENS', 4096, isProduction, 16_384),
      systemPrompt: CHAT_SYSTEM_PROMPT,
    },
    trial: {
      apiKey: trialApiKey,
      allowedModels: trialModels,
      defaultModel: trialDefaultModel,
      maxConcurrency: boundedPositiveInteger(env, 'TRIAL_MAX_CONCURRENCY', 2, isProduction, 10),
      dailyTokenLimit: boundedPositiveInteger(env, 'TRIAL_DAILY_TOKEN_LIMIT', 50_000, isProduction, 10_000_000),
      dailySpendMicroUsd: boundedPositiveInteger(env, 'TRIAL_DAILY_SPEND_MICRO_USD', 250_000, isProduction, 100_000_000),
    },
    scheduler: {
      maxTasksPerUser: boundedPositiveInteger(env, 'SCHEDULER_MAX_TASKS_PER_USER', 5, isProduction, 5),
      minIntervalMs: boundedPositiveInteger(
        env,
        'SCHEDULER_MIN_INTERVAL_MS',
        15 * 60_000,
        isProduction,
        86_400_000,
        15 * 60_000,
      ),
      maxTokens: boundedPositiveInteger(env, 'SCHEDULER_MAX_TOKENS', 1024, isProduction, 4096),
      claimLimit: boundedPositiveInteger(env, 'SCHEDULER_CLAIM_LIMIT', 10, isProduction, 100),
    },
    defaultModels: {
      anthropic: 'claude-sonnet-4-6',
      openai: 'gpt-5',
      openrouter: 'anthropic/claude-sonnet-4-6',
    } as Record<ProviderType, string>,
    composio: {
      apiKey: env.COMPOSIO_API_KEY || '',
      authConfigIds: composioAuthConfigIds,
    },
    dodo: {
      apiKey: dodoApiKey,
      webhookKey: dodoWebhookKey,
      productId: dodoProductId,
      returnUrl: dodoReturnUrl,
      environment: dodoEnvironment,
      expectedAmount: dodoExpectedAmount,
      expectedCurrency: dodoExpectedCurrency,
      expectedQuantity: dodoExpectedQuantity,
    },
  } as const;
}

export const config = loadConfig();
