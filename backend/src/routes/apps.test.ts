import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { test } from 'node:test';

test('OAuth attempts are one-use and bound to owner, device, app, and exact callback', async () => {
  const stateSource = await readFile(
    new URL('../composio/oauth-state.ts', import.meta.url),
    'utf8',
  );
  assert.match(stateSource, /\.eq\('user_id', input\.userId\)/);
  assert.match(stateSource, /\.eq\('device_id', input\.deviceId\)/);
  assert.match(stateSource, /\.eq\('app_type', input\.appType\)/);
  assert.match(stateSource, /\.is\('consumed_at', null\)/);
  assert.match(stateSource, /\.gt\('expires_at'/);
  assert.match(stateSource, /callback\.pathname !== `\/api\/apps\/\$\{input\.appType\}\/callback`/);
  assert.match(stateSource, /callback\.searchParams\.get\('state'\) !== input\.state/);
});

test('only one replacement attempt per owner and app remains active across devices', async () => {
  const sql = await readFile(
    new URL('../../sql/011_identity_oauth_actions_scheduler.sql', import.meta.url),
    'utf8',
  );
  assert.match(
    sql,
    /danotch_oauth_link_attempts_one_active_idx\s+on public\.danotch_oauth_link_attempts\(user_id, app_type\)/,
  );
  assert.doesNotMatch(
    sql,
    /danotch_oauth_link_attempts_one_active_idx\s+on public\.danotch_oauth_link_attempts\(user_id, device_id, app_type\)/,
  );
});

test('replacement persists the candidate before retiring the prior account', async () => {
  const routeSource = await readFile(new URL('./apps.ts', import.meta.url), 'utf8');
  const persist = routeSource.indexOf('const persisted = await syncConnectionToDb');
  const retire = routeSource.indexOf('await retireSupersededAccount');
  assert.ok(persist >= 0 && retire > persist);
  assert.match(routeSource, /if \(!persisted\)[\s\S]*connection_persistence_unavailable/);
  assert.doesNotMatch(routeSource, /router\.post\('\/reset'/);
  assert.match(routeSource, /consumeOAuthCallback\(\{[\s\S]*appType/);
});
