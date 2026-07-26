import assert from 'node:assert/strict';
import { randomBytes } from 'node:crypto';
import { test } from 'node:test';
import { readInstallationSecret } from './bootstrap.ts';
import { KeychainBroker } from './keychain-broker.ts';

test('native-host shim is preferred without touching inherited fd channels', async () => {
  const secret = randomBytes(32);
  const values = new Map<string, string>();
  const operations: string[] = [];
  const previous = globalThis.__perchNativeHost;
  globalThis.__perchNativeHost = {
    installationSecret: secret.toString('base64'),
    async getCredential(credential) {
      operations.push(`get:${credential}`);
      return values.get(credential);
    },
    async setCredential(credential, value) {
      operations.push(`set:${credential}`);
      values.set(credential, value);
    },
    async deleteCredential(credential) {
      operations.push(`delete:${credential}`);
      values.delete(credential);
    },
  };

  try {
    assert.deepEqual(await readInstallationSecret(), secret);
    const broker = new KeychainBroker();
    await broker.setCredential('provider.anthropic', 'transient-key');
    assert.equal(await broker.getCredential('provider.anthropic'), 'transient-key');
    await broker.deleteCredential('provider.anthropic');
    assert.deepEqual(operations, [
      'set:provider.anthropic',
      'get:provider.anthropic',
      'delete:provider.anthropic',
    ]);
    broker.close();
  } finally {
    globalThis.__perchNativeHost = previous;
  }
});
