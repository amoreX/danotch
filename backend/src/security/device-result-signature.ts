import { createHash, createPublicKey, verify } from 'node:crypto';
import { stableCanonicalJSON } from './execution-grant.js';

export interface SignedDeviceResult {
  messageId: string;
  deviceId: string;
  sessionId: string;
  fence: number;
  actionId: string;
  grantId: string;
  status: string;
  result: Record<string, unknown>;
}

export function deviceResultSigningPayload(value: SignedDeviceResult): Buffer {
  const resultHash = createHash('sha256')
    .update(stableCanonicalJSON(value.result))
    .digest('hex');
  return Buffer.from([
    'perch-action-result',
    '1',
    value.messageId.toLowerCase(),
    value.deviceId.toLowerCase(),
    value.sessionId.toLowerCase(),
    String(value.fence),
    value.actionId.toLowerCase(),
    value.grantId.toLowerCase(),
    value.status,
    resultHash,
  ].join('\n'));
}

export function verifyDeviceResultSignature(
  value: SignedDeviceResult,
  publicKeyPEM: string,
  algorithm: string,
  signature: string,
): boolean {
  try {
    const key = createPublicKey({ key: publicKeyPEM, format: 'pem', type: 'spki' });
    if (
      algorithm !== 'P-256'
      || key.asymmetricKeyType !== 'ec'
      || key.asymmetricKeyDetails?.namedCurve !== 'prime256v1'
    ) return false;
    const bytes = Buffer.from(signature, 'base64url');
    return bytes.length >= 8
      && bytes.length <= 80
      && verify('sha256', deviceResultSigningPayload(value), key, bytes);
  } catch {
    return false;
  }
}
