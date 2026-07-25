import assert from 'node:assert/strict';
import { randomBytes } from 'node:crypto';
import { createServer, request } from 'node:http';
import type { AddressInfo } from 'node:net';
import { test } from 'node:test';
import { createApp } from './app.ts';
import { loadConfig } from './config.ts';
import { openDatabase } from './db/database.ts';
import { Repositories } from './db/repositories.ts';
import { NotchBridge } from './events/notch.ts';
import type { Credential, SecretBroker } from './ipc/keychain-broker.ts';
import { SessionManager } from './security/session.ts';
import { ActionCoordinator } from './actions/coordinator.ts';
import { LocalComposioService, type ComposioClient } from './composio/service.ts';

test('loopback API enforces Host, Origin, session auth, and secret rejection', async () => {
  const db = openDatabase(':memory:');
  const repos = new Repositories(db);
  const secret = randomBytes(32);
  const encoded = secret.toString('base64');
  const sessions = new SessionManager(Buffer.from(secret), 60_000);
  const config = loadConfig({});
  const credentials = new Map<Credential, string>();
  const broker: SecretBroker = {
    async getCredential(credential) { return credentials.get(credential); },
    async setCredential(credential, value) { credentials.set(credential, value); },
    async deleteCredential(credential) { credentials.delete(credential); },
    close() {},
  };
  let verifiedSecret: string | undefined;
  const events = new NotchBridge();
  const actions = new ActionCoordinator(repos, events);
  const composioClient = {
    connectedAccounts: {
      async list() { return { items: [] }; },
      async link() { return { redirectUrl: 'https://connect.composio.example/link' }; },
      async delete() {},
    },
    authConfigs: { async list() { return { items: [{ id: 'gmail-auth' }] }; } },
    tools: { async get() { return []; } },
    provider: { async handleToolCalls() { return [{ content: '{"ok":true}' }]; } },
  } as ComposioClient;
  const composio = new LocalComposioService(repos, broker, () => composioClient);
  let port = 0;
  const app = createApp({
    config, repositories: repos, broker, sessions, events,
    getPort: () => port, instanceId: 'test-instance',
    actions, composio,
    async verifyProviderCredential(input) { verifiedSecret = input.apiKey; },
  });
  const server = createServer(app);
  await new Promise<void>((resolve) => server.listen(0, '127.0.0.1', resolve));
  port = (server.address() as AddressInfo).port;
  const base = `http://127.0.0.1:${port}`;
  const originalLog = console.error;
  const logs: string[] = [];
  console.error = (...values) => logs.push(values.map(String).join(' '));
  try {
    const missingOrigin = await fetch(`${base}/health/live`);
    assert.equal(missingOrigin.status, 403);
    const readiness = await fetch(`${base}/health/ready`, {
      headers: { origin: config.allowedOrigin },
    });
    assert.equal(readiness.status, 200);

    const wrongOrigin = await fetch(`${base}/ipc/session`, {
      method: 'POST',
      headers: { 'content-type': 'application/json', origin: 'https://evil.example' },
      body: JSON.stringify({ installationSecret: encoded }),
    });
    assert.equal(wrongOrigin.status, 403);

    assert.equal(await postWithHost(port, 'localhost', encoded), 400);

    const exchanged = await fetch(`${base}/ipc/session`, {
      method: 'POST',
      headers: { 'content-type': 'application/json', origin: config.allowedOrigin },
      body: JSON.stringify({ installationSecret: encoded }),
    });
    assert.equal(exchanged.status, 200);
    const { token } = await exchanged.json() as { token: string };

    const rejected = await fetch(`${base}/api/provider`, {
      method: 'POST',
      headers: {
        'content-type': 'application/json',
        authorization: `Bearer ${token}`,
        origin: config.allowedOrigin,
      },
      body: JSON.stringify({
        provider: 'openai',
        model_id: 'gpt-5',
        keychain_account: 'openai',
        api_key: 'must-not-cross-http',
      }),
    });
    assert.equal(rejected.status, 400);
    assert.match((await rejected.json() as { error: string }).error, /Keychain/);
    assert.equal(rejected.headers.get('access-control-allow-origin'), null);

    const localSession = await fetch(`${base}/v1/session`, {
      method: 'POST',
      headers: { 'content-type': 'application/json', origin: config.allowedOrigin },
      body: JSON.stringify({
        installation_secret: encoded,
        installation_id: 'installation-test',
        instance_id: 'test-instance',
        protocol_versions: [1],
      }),
    });
    assert.equal(localSession.status, 200);
    const localSessionBody = await localSession.json() as Record<string, unknown>;
    assert.equal(typeof localSessionBody.session_token, 'string');
    assert.equal(localSessionBody.websocket_path, '/v1/events');
    assert.equal(localSessionBody.protocol_version, 1);
    const localHeaders = {
      'content-type': 'application/json',
      authorization: `Bearer ${localSessionBody.session_token as string}`,
      origin: config.allowedOrigin,
    };

    const rawKey = 'raw-save-secret-value';
    const saved = await fetch(`${base}/v1/config/providers`, {
      method: 'PUT',
      headers: localHeaders,
      body: JSON.stringify({ provider: 'openai', model_id: 'gpt-5', api_key: rawKey }),
    });
    assert.equal(saved.status, 200);
    assert.equal(credentials.get('provider.openai'), rawKey);
    assert.equal(repos.getProviderByType('openai')?.keychain_account, 'provider.openai');
    const persisted = JSON.stringify(repos.db.prepare('SELECT * FROM provider_preferences').all());
    assert.equal(persisted.includes(rawKey), false);

    const verifyKey = 'verify-only-secret';
    const verified = await fetch(`${base}/v1/config/providers/verify`, {
      method: 'POST',
      headers: localHeaders,
      body: JSON.stringify({ provider: 'openai', model_id: 'gpt-5', api_key: verifyKey }),
    });
    assert.deepEqual(await verified.json(), {
      verified: true,
      provider: 'openai',
      model_id: 'gpt-5',
    });
    assert.equal(verifiedSecret, verifyKey);
    assert.equal(JSON.stringify(repos.db.prepare('SELECT * FROM provider_preferences').all()).includes(verifyKey), false);

    const providers = await fetch(`${base}/v1/config/providers`, { headers: localHeaders });
    const providerBody = await providers.json() as { providers: Record<string, unknown>[] };
    assert.deepEqual(providerBody.providers[0], {
      id: 'openai',
      provider: 'openai',
      model_id: 'gpt-5',
      base_url: null,
      is_active: true,
      verified_at: null,
    });

    const scheduled = await fetch(`${base}/v1/scheduled`, {
      method: 'POST',
      headers: localHeaders,
      body: JSON.stringify({
        name: 'Daily check',
        prompt: 'Check status',
        task_type: 'scheduled',
        cron: '0 9 * * *',
        provider: 'openai',
        model_id: 'gpt-5',
        notify_user: true,
      }),
    });
    assert.equal(scheduled.status, 201);
    const scheduledBody = await scheduled.json() as { task: Record<string, unknown> };
    assert.equal(scheduledBody.task.provider, 'openai');
    assert.equal(scheduledBody.task.enabled, true);
    assert.equal(scheduledBody.task.notify_user, true);

    repos.createNotification('scheduled_task', 'source', 'Title', 'Body');
    const notifications = await fetch(`${base}/v1/notifications`, { headers: localHeaders });
    const notificationBody = await notifications.json() as { notifications: Record<string, unknown>[] };
    assert.equal(notificationBody.notifications[0]?.read, false);

    credentials.set('composio', 'temporary-action-key');
    const action = repos.createPendingAction(null, 'GMAIL_SEND_EMAIL', 'Send email', {}) as { id: string };
    const actionResponse = await fetch(`${base}/v1/actions/${action.id}/approve`, {
      method: 'POST', headers: localHeaders, body: '{}',
    });
    assert.equal(actionResponse.status, 200);

    const blockedSecret = await fetch(`${base}/v1/chat`, {
      method: 'POST',
      headers: localHeaders,
      body: JSON.stringify({ message: 'hello', options: { api_key: 'blocked-secret' } }),
    });
    assert.equal(blockedSecret.status, 400);

    const composioKey = 'composio-local-secret';
    const composioSaved = await fetch(`${base}/v1/config/composio`, {
      method: 'PUT',
      headers: localHeaders,
      body: JSON.stringify({ api_key: composioKey }),
    });
    assert.equal((await composioSaved.json() as { configured: boolean }).configured, true);
    const composioMetadata = await fetch(`${base}/v1/config/composio`, {
      method: 'PUT',
      headers: localHeaders,
      body: JSON.stringify({ auth_config_ids: { gmail: 'gmail-auth-config' } }),
    });
    assert.equal(composioMetadata.status, 200);
    assert.equal(repos.getIntegrationConfig('gmail')?.auth_config_id, 'gmail-auth-config');
    const composioState = await fetch(`${base}/v1/config/composio`, { headers: localHeaders });
    assert.equal((await composioState.json() as { configured: boolean }).configured, true);
    const supported = await fetch(`${base}/v1/integrations/gmail/connect`, {
      method: 'POST', headers: localHeaders, body: '{}',
    });
    assert.equal(supported.status, 200);
    assert.equal((await supported.json() as { connected: boolean }).connected, false);

    const deleted = await fetch(`${base}/v1/config/providers/openai`, {
      method: 'DELETE', headers: localHeaders,
    });
    assert.equal(deleted.status, 200);
    assert.equal(credentials.has('provider.openai'), false);
    assert.equal(repos.getProviderByType('openai'), undefined);

    assert.equal(logs.join('\n').includes(rawKey), false);
    assert.equal(logs.join('\n').includes(verifyKey), false);
    assert.equal(logs.join('\n').includes(composioKey), false);
    assert.equal(logs.join('\n').includes('blocked-secret'), false);
  } finally {
    console.error = originalLog;
    await new Promise<void>((resolve) => server.close(() => resolve()));
    sessions.close();
    db.close();
  }
});

function postWithHost(port: number, host: string, installationSecret: string): Promise<number> {
  const body = JSON.stringify({ installationSecret });
  return new Promise((resolve, reject) => {
    const req = request({
      hostname: '127.0.0.1',
      port,
      path: '/ipc/session',
      method: 'POST',
      headers: {
        host,
        'content-type': 'application/json',
        'content-length': Buffer.byteLength(body),
      },
    }, (res) => {
      res.resume();
      res.once('end', () => resolve(res.statusCode ?? 0));
    });
    req.once('error', reject);
    req.end(body);
  });
}
