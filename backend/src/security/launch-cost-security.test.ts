import assert from 'node:assert/strict';
import { readFile, readdir } from 'node:fs/promises';
import { join } from 'node:path';
import { test } from 'node:test';
import ts from 'typescript';

async function productionTypeScriptFiles(directory: string): Promise<string[]> {
  const entries = await readdir(directory, { withFileTypes: true });
  const files = await Promise.all(entries.map(async (entry) => {
    const path = join(directory, entry.name);
    if (entry.isDirectory()) return productionTypeScriptFiles(path);
    return entry.name.endsWith('.ts') && !entry.name.endsWith('.test.ts') ? [path] : [];
  }));
  return files.flat();
}

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

test('trial usage meter reads account-scoped daily and durable totals', async () => {
  const sql = await readFile(
    new URL('../../sql/016_trial_usage_summary.sql', import.meta.url),
    'utf8',
  );
  assert.match(sql, /v_user_id uuid := auth\.uid\(\)/);
  assert.match(sql, /usage_day = \(now\(\) at time zone 'UTC'\)::date/);
  assert.match(sql, /'reason', 'daily_spend'/);
  assert.match(sql, /limit_reached_at = coalesce\(limit_reached_at, now\(\)\)/);
  assert.match(sql, /requests_used = public\.danotch_trial_usage_daily\.requests_used \+ 1/);
  assert.match(sql, /coalesce\(sum\(requests_used\), 0\)/);
  assert.match(sql, /coalesce\(sum\(tokens_used\), 0\)/);
  assert.match(sql, /coalesce\(sum\(spend_micro_usd\), 0\)/);
  assert.match(sql, /grant execute.*authenticated/s);
  assert.match(sql, /create function public\.danotch_get_trial_usage_summary\(\)/);
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
  assert.match(scheduler, /resolveProviderForUser/);
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

test('production logs cannot include user content, identifiers, or raw errors', async () => {
  const sourceRoot = new URL('../', import.meta.url).pathname;
  const files = await productionTypeScriptFiles(sourceRoot);
  const forbidden = new Set([
    'message',
    'prompt',
    'query',
    'url',
    'inputSummary',
    'resultSummary',
    'userId',
    'taskId',
    'taskName',
    'paymentId',
    'conversation_id',
    'session_id',
    'payload',
    'updates',
    'title',
    'err',
    'error',
  ]);

  for (const file of files) {
    const sourceText = await readFile(file, 'utf8');
    const source = ts.createSourceFile(file, sourceText, ts.ScriptTarget.Latest, true);

    const visit = (node: ts.Node): void => {
      if (
        ts.isCallExpression(node)
        && ts.isPropertyAccessExpression(node.expression)
        && ts.isIdentifier(node.expression.expression)
        && node.expression.expression.text === 'console'
        && ['log', 'warn', 'error'].includes(node.expression.name.text)
      ) {
        const loggedExpressions = node.arguments.map((argument) => argument.getText(source)).join(' ');
        const identifiers = new Set<string>();
        const collectIdentifiers = (argumentNode: ts.Node): void => {
          if (ts.isIdentifier(argumentNode)) identifiers.add(argumentNode.text);
          ts.forEachChild(argumentNode, collectIdentifiers);
        };
        node.arguments.forEach(collectIdentifiers);
        const sensitiveIdentifiers = [...identifiers].filter((identifier) => forbidden.has(identifier));
        assert.deepEqual(
          sensitiveIdentifiers,
          [],
          `${file} logs potentially sensitive expressions (${sensitiveIdentifiers.join(', ')}): ${loggedExpressions}`,
        );
      }
      ts.forEachChild(node, visit);
    };

    visit(source);
  }
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
  assert.match(render, /key: TRIAL_DAILY_SPEND_MICRO_USD\s+value: "5000000"/);
  assert.match(render, /key: TRIAL_INPUT_MICRO_USD_PER_TOKEN\s+value: "3"/);
  assert.match(render, /key: TRIAL_OUTPUT_MICRO_USD_PER_TOKEN\s+value: "15"/);
  assert.match(render, /healthCheckPath: \/health\/ready/);
});
