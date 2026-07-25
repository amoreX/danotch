import assert from 'node:assert/strict';
import { test } from 'node:test';
import { validateProviderEndpoint } from './factory.ts';

test('custom provider endpoints require credential-free public HTTPS', async () => {
  const publicLookup = async () => ['203.0.113.20'];
  // Documentation ranges are blocked even when returned by DNS.
  await assert.rejects(
    validateProviderEndpoint('https://models.example/v1', publicLookup),
    /public addresses/,
  );
  assert.equal(
    await validateProviderEndpoint('https://models.example/v1', async () => ['8.8.8.8']),
    'https://models.example/v1',
  );
  await assert.rejects(validateProviderEndpoint('http://models.example/v1', async () => ['8.8.8.8']));
  await assert.rejects(validateProviderEndpoint('https://user:pass@models.example/v1', async () => ['8.8.8.8']));
  await assert.rejects(validateProviderEndpoint('https://127.0.0.1/v1'));
  await assert.rejects(validateProviderEndpoint('https://models.example:8443/v1', async () => ['8.8.8.8']));
});
