import assert from 'node:assert/strict';
import { test } from 'node:test';
import { loadConfig } from './config.ts';

function production(overrides: Record<string, string | undefined> = {}) {
  return {
    NODE_ENV: 'production',
    PORT: '3001',
    PUBLIC_BASE_URL: 'https://api.example.com',
    DEVICE_GATEWAY_URL: 'wss://api.example.com/api/device-gateway',
    NOTCH_WS_URL: 'wss://legacy.example.com/ws',
    DEVICE_TICKET_SIGNING_SECRET: 'production-ticket-signing-secret-32-bytes-minimum',
    TRUST_PROXY: '1',
    DEVICE_ALLOWED_ORIGINS: 'perch://app',
    JSON_BODY_LIMIT_BYTES: '65536',
    DEVICE_FRESH_AUTH_MAX_AGE_MS: '300000',
    DEVICE_CHALLENGE_TTL_MS: '60000',
    DEVICE_TICKET_TTL_MS: '30000',
    DEVICE_MAX_PER_USER: '3',
    DEVICE_MAX_PAYLOAD_BYTES: '65536',
    DEVICE_MAX_MESSAGES_PER_WINDOW: '120',
    DEVICE_MAX_BYTES_PER_WINDOW: '524288',
    DEVICE_RATE_WINDOW_MS: '60000',
    DEVICE_MAX_CONNECTION_BYTES: '16777216',
    DEVICE_MAX_BUFFERED_BYTES: '262144',
    DEVICE_HEARTBEAT_INTERVAL_MS: '20000',
    DEVICE_HEARTBEAT_TIMEOUT_MS: '60000',
    DEVICE_HANDSHAKE_TIMEOUT_MS: '5000',
    DEVICE_REPLAY_PAGE_SIZE: '100',
    DEVICE_WAITING_EXPIRY_SWEEP_MS: '30000',
    CAPTCHA_PROVIDER: 'turnstile',
    CAPTCHA_SECRET: 'captcha-secret',
    CAPTCHA_SITE_KEY: 'captcha-site-key',
    CAPTCHA_EXPECTED_HOSTNAME: 'api.example.com',
    OAUTH_STATE_TTL_MS: '600000',
    PROVIDER_KEY_SECRET: 'production-provider-key-secret-that-is-32-plus-characters',
    ...overrides,
  };
}

test('production device gateway config requires explicit secure origins, signing, proxy, and limits', () => {
  const loaded = loadConfig(production());
  assert.equal(loaded.publicBaseUrl, 'https://api.example.com');
  assert.equal(loaded.deviceGateway.publicUrl, 'wss://api.example.com/api/device-gateway');
  assert.equal(loaded.trustProxy, 1);

  assert.throws(
    () => loadConfig(production({ DEVICE_TICKET_SIGNING_SECRET: undefined })),
    /DEVICE_TICKET_SIGNING_SECRET/,
  );
  assert.throws(() => loadConfig(production({ TRUST_PROXY: undefined })), /TRUST_PROXY/);
  assert.throws(() => loadConfig(production({ DEVICE_MAX_PAYLOAD_BYTES: undefined })), /DEVICE_MAX_PAYLOAD_BYTES/);
  assert.throws(() => loadConfig(production({ CAPTCHA_SECRET: undefined })), /CAPTCHA_SECRET/);
  assert.throws(
    () => loadConfig(production({ COSTLY_INTEGRATIONS_ENABLED: 'true' })),
    /COMPOSIO_AUTH_CONFIG/,
  );
});

test('production rejects HTTP, WS, localhost, wildcard origins, and invalid limits', () => {
  assert.throws(() => loadConfig(production({ PUBLIC_BASE_URL: 'http://api.example.com' })), /HTTPS/);
  assert.throws(() => loadConfig(production({ DEVICE_GATEWAY_URL: 'ws://api.example.com/ws' })), /WSS/);
  assert.throws(() => loadConfig(production({ NOTCH_WS_URL: 'wss://localhost/ws' })), /localhost/);
  assert.throws(() => loadConfig(production({ DEVICE_ALLOWED_ORIGINS: '*' })), /wildcard/);
  assert.throws(() => loadConfig(production({ DEVICE_MAX_PAYLOAD_BYTES: '0' })), /positive integer/);
});

test('production rejects insecure PROVIDER_KEY_SECRET fallbacks', () => {
  // Missing PROVIDER_KEY_SECRET must fail in production.
  assert.throws(
    () => loadConfig(production({ PROVIDER_KEY_SECRET: undefined })),
    /PROVIDER_KEY_SECRET/,
  );
  // A short/weak key must fail in production.
  assert.throws(
    () => loadConfig(production({ PROVIDER_KEY_SECRET: 'too-short' })),
    /PROVIDER_KEY_SECRET/,
  );
});

test('production accepts a sufficiently long PROVIDER_KEY_SECRET', () => {
  const loaded = loadConfig(
    production({ PROVIDER_KEY_SECRET: 'a-production-secret-key-that-is-long-enough-for-aes256' }),
  );
  // Key is present in config (length validated).
  assert.ok(loaded.providerKeySecret.length >= 32);
});

test('development allows a missing or short PROVIDER_KEY_SECRET', () => {
  // Development should not throw on missing key — crypto.ts will throw lazily.
  assert.doesNotThrow(() =>
    loadConfig({ NODE_ENV: 'development', PORT: '3001', DEVICE_ALLOWED_ORIGINS: 'perch://app' }),
  );
});
