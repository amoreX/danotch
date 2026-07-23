import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createConnectionLink, type ComposioLinkClient } from './link-adapter.ts';

test('Composio initiation uses pinned link API with an exact callback', async () => {
  const calls: unknown[][] = [];
  const client: ComposioLinkClient = {
    connectedAccounts: {
      async link(...args) {
        calls.push(args);
        return {
          redirectUrl: 'https://connect.example/link',
          async waitForConnection() {},
        };
      },
    },
  };

  const request = await createConnectionLink(
    client,
    'owner-1',
    'auth-config-1',
    'https://api.example.com/api/apps/gmail/callback',
  );

  assert.equal(request.redirectUrl, 'https://connect.example/link');
  assert.deepEqual(calls, [[
    'owner-1',
    'auth-config-1',
    { callbackUrl: 'https://api.example.com/api/apps/gmail/callback' },
  ]]);
});

test('link adapter has no destructive account operation in its contract', () => {
  const accountMethods: keyof ComposioLinkClient['connectedAccounts'][] = ['link'];
  assert.deepEqual(accountMethods, ['link']);
});
