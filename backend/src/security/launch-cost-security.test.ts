import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { test } from 'node:test';

test('trial migration atomically enforces daily tokens, spend, and concurrency', async () => {
  const sql = await readFile(
    new URL('../../sql/014_trial_cost_security.sql', import.meta.url),
    'utf8',
  );
  assert.match(sql, /pg_advisory_xact_lock/);
  assert.match(sql, /active_count >= p_max_concurrency/);
  assert.match(sql, /daily\.tokens_used \+ reserved_tokens \+ p_reserved_tokens/);
  assert.match(sql, /daily\.spend_micro_usd \+ reserved_spend \+ p_reserved_spend_micro_usd/);
  assert.match(sql, /danotch_settle_trial_usage/);
  assert.match(sql, /force row level security/);
});

test('server trial model is allowlisted and never reads the legacy fallback key', async () => {
  const source = await readFile(new URL('../providers/factory.ts', import.meta.url), 'utf8');
  assert.match(source, /config\.trial\.allowedModels\.includes\(selectedModel\)/);
  assert.match(source, /config\.trial\.apiKey/);
  assert.doesNotMatch(source, /process\.env\.ANTHROPIC_API_KEY/);
});

test('scheduler has database and application frequency, count, claim, and token caps', async () => {
  const sql = await readFile(
    new URL('../../sql/014_trial_cost_security.sql', import.meta.url),
    'utf8',
  );
  const scheduler = await readFile(new URL('../scheduler/index.ts', import.meta.url), 'utf8');
  const tools = await readFile(new URL('../tools/scheduled.ts', import.meta.url), 'utf8');
  assert.match(sql, /count\(\*\).*>= 5/s);
  assert.match(sql, /new\.interval_ms < 900000/);
  assert.match(scheduler, /p_limit: config\.scheduler\.claimLimit/);
  assert.match(scheduler, /maxTokens: config\.scheduler\.maxTokens/);
  assert.match(tools, /isCronAtLeastInterval/);
});

test('auth endpoints are rate limited and upstream errors are not returned raw', async () => {
  const auth = await readFile(new URL('../routes/auth.ts', import.meta.url), 'utf8');
  const tasks = await readFile(new URL('../routes/tasks.ts', import.meta.url), 'utf8');
  const runner = await readFile(new URL('../agent/runner.ts', import.meta.url), 'utf8');
  assert.match(auth, /router\.post\('\/login', loginLimiter/);
  assert.match(auth, /router\.post\('\/refresh', refreshLimiter/);
  assert.match(tasks, /The request could not be completed\./);
  assert.match(runner, /Provider stream interrupted/);
});

test('remote migrations verify TLS and support an explicit CA', async () => {
  const source = await readFile(
    new URL('../../scripts/migrate.mjs', import.meta.url),
    'utf8',
  );
  assert.match(source, /DATABASE_SSL_CA_FILE/);
  assert.match(source, /rejectUnauthorized: true/);
  assert.doesNotMatch(source, /rejectUnauthorized: false/);
});

test('Render blueprint declares every launch trust boundary and remains frozen by default', async () => {
  const render = await readFile(new URL('../../render.yaml', import.meta.url), 'utf8');
  for (const key of [
    'SUPABASE_URL',
    'SUPABASE_PUBLISHABLE_KEY',
    'SUPABASE_BOOTSTRAP_SECRET_KEY',
    'SUPABASE_WEBHOOK_SECRET_KEY',
    'SUPABASE_SCHEDULER_SECRET_KEY',
    'SUPABASE_FENCING_SECRET_KEY',
    'SUPABASE_RECONCILIATION_SECRET_KEY',
    'SUPABASE_PROVIDER_SECRET_KEY',
    'SUPABASE_RUNNER_SECRET_KEY',
    'PROVIDER_KEY_SECRET',
    'CAPTCHA_SECRET',
    'TRIAL_ANTHROPIC_API_KEY',
    'DODO_PAYMENTS_WEBHOOK_KEY',
  ]) {
    assert.match(render, new RegExp(`key: ${key}`));
  }
  assert.match(render, /key: PUBLIC_SIGNUP_ENABLED\s+value: "false"/);
  assert.match(render, /key: TRIALS_ENABLED\s+value: "false"/);
  assert.match(render, /healthCheckPath: \/health\/ready/);
});
