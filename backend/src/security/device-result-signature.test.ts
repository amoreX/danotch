import assert from 'node:assert/strict';
import { generateKeyPairSync, sign } from 'node:crypto';
import { test } from 'node:test';
import {
  deviceResultSigningPayload,
  verifyDeviceResultSignature,
} from './device-result-signature.ts';

test('device result signature binds session fence result and idempotency key', () => {
  const keys = generateKeyPairSync('ec', { namedCurve: 'prime256v1' });
  const value = {
    messageId: '10000000-0000-4000-8000-000000000001',
    deviceId: '20000000-0000-4000-8000-000000000002',
    sessionId: '30000000-0000-4000-8000-000000000003',
    fence: 7,
    actionId: '40000000-0000-4000-8000-000000000004',
    grantId: '50000000-0000-4000-8000-000000000005',
    status: 'completed',
    result: { stdout: 'ok', exit_code: 0 },
  };
  const signature = sign(
    'sha256',
    deviceResultSigningPayload(value),
    keys.privateKey,
  ).toString('base64url');
  const publicKey = keys.publicKey.export({ type: 'spki', format: 'pem' }).toString();
  assert.equal(verifyDeviceResultSignature(value, publicKey, 'P-256', signature), true);
  assert.equal(verifyDeviceResultSignature(
    { ...value, fence: 8 },
    publicKey,
    'P-256',
    signature,
  ), false);
  assert.equal(verifyDeviceResultSignature(
    { ...value, result: { stdout: 'tampered' } },
    publicKey,
    'P-256',
    signature,
  ), false);
});
