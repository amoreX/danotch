import assert from 'node:assert/strict';
import { test } from 'node:test';
import { openDatabase } from '../db/database.ts';
import { Repositories } from '../db/repositories.ts';
import type { SecretBroker } from '../ipc/keychain-broker.ts';
import { LocalComposioService, type ComposioClient } from './service.ts';

test('Composio hosted link remains pending and disconnect removes every account', async () => {
  const db = openDatabase(':memory:');
  try {
    const repositories = new Repositories(db);
    let keySeen = '';
    const deleted: string[] = [];
    let accounts = [
      { id: 'pending-1', status: 'INITIATED' },
      { id: 'pending-2', status: 'INITIATED' },
    ];
    const client = {
      connectedAccounts: {
        async list() { return { items: accounts }; },
        async link(_userId: string, authConfigId: string) {
          assert.equal(authConfigId, 'gmail-auth');
          return { redirectUrl: 'https://connect.composio.example/hosted' };
        },
        async delete(id: string) { deleted.push(id); },
      },
      authConfigs: { async list() { return { items: [{ id: 'gmail-auth' }] }; } },
      tools: { async get() { return []; } },
      provider: { async handleToolCalls() { return []; } },
    } as ComposioClient;
    const broker: SecretBroker = {
      async getCredential(credential) { return credential === 'composio' ? 'key-from-keychain' : undefined; },
      async setCredential() {},
      async deleteCredential() {},
      close() {},
    };
    const service = new LocalComposioService(repositories, broker, (key) => {
      keySeen = key;
      return client;
    });
    const linked = await service.connect('gmail');
    assert.equal(linked.connected, false);
    assert.equal(linked.status, 'pending');
    assert.equal(linked.redirect_url, 'https://connect.composio.example/hosted');
    assert.equal(keySeen, 'key-from-keychain');
    assert.equal(JSON.stringify(repositories.db.prepare('SELECT * FROM connections').all())
      .includes('key-from-keychain'), false);

    accounts = [
      { id: 'active-1', status: 'ACTIVE' },
      { id: 'duplicate-2', status: 'ACTIVE' },
    ];
    assert.equal((await service.status('gmail')).connected, true);
    const result = await service.disconnect('gmail');
    assert.deepEqual(deleted, ['active-1', 'duplicate-2']);
    assert.equal(result.deleted_accounts, 2);
    assert.equal(repositories.listConnections().length, 0);
  } finally {
    db.close();
  }
});

test('Composio tools are curated and mutation policy remains approval-gated', async () => {
  const db = openDatabase(':memory:');
  try {
    const repositories = new Repositories(db);
    const client = {
      connectedAccounts: {
        async list() { return { items: [{ id: 'active', status: 'ACTIVE' }] }; },
        async link() { return {}; },
        async delete() {},
      },
      authConfigs: { async list() { return { items: [] }; } },
      tools: {
        async get(_userId: string, input: { tools: string[] }) {
          return [
            ...input.tools.slice(0, 1).map((name) => ({
              name, description: name, input_schema: { type: 'object', properties: {} },
            })),
            { name: 'UNREVIEWED_TOOL', description: 'bad', input_schema: {} },
          ];
        },
      },
      provider: { async handleToolCalls() { return [{ content: 'ok' }]; } },
    } as ComposioClient;
    const broker = {
      async getCredential() { return 'key'; },
      async setCredential() {},
      async deleteCredential() {},
      close() {},
    } as SecretBroker;
    const service = new LocalComposioService(repositories, broker, () => client);
    const loaded = await service.loadTools();
    assert.equal(loaded.names.has('UNREVIEWED_TOOL'), false);
    assert.equal(service.policy('GMAIL_FETCH_EMAILS'), 'read');
    assert.equal(service.policy('GMAIL_SEND_EMAIL'), 'approval');
  } finally {
    db.close();
  }
});
