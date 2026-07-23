import { generateKeyPairSync, sign } from 'node:crypto';
import { createServer } from 'node:http';
import assert from 'node:assert/strict';
import { afterEach, test } from 'node:test';
import express, { type RequestHandler } from 'express';
import { createDeviceRoutes } from './devices.ts';
import {
  DeviceService,
  InMemoryDeviceStore,
  deviceChallengeMessage,
} from '../devices/device-service.ts';

const servers: Array<ReturnType<typeof createServer>> = [];

afterEach(async () => {
  await Promise.all(servers.splice(0).map((server) => new Promise<void>((resolve) => server.close(() => resolve()))));
});

function auth(userId: string, issuedAt = Date.now()): RequestHandler {
  return (req, _res, next) => {
    req.user = { sub: userId, email: `${userId}@example.test`, role: 'authenticated', authTime: issuedAt };
    next();
  };
}

async function fixture(options: { userId?: string; issuedAt?: number; maxDevices?: number } = {}) {
  const now = { value: Date.now() };
  const store = new InMemoryDeviceStore(() => now.value);
  const service = new DeviceService(store, {
    signingSecret: 'test-ticket-secret-that-is-at-least-32-bytes',
    issuer: 'https://api.example.test',
    audience: 'wss://api.example.test/api/device-gateway',
    challengeTtlMs: 60_000,
    ticketTtlMs: 30_000,
    maxDevicesPerUser: options.maxDevices ?? 2,
    supportedProtocolVersions: [1],
    now: () => now.value,
  });
  const app = express();
  app.use(express.json({ limit: '16kb' }));
  app.use('/api/devices', createDeviceRoutes({
    service,
    requireAuth: auth(options.userId ?? 'user-a', options.issuedAt ?? now.value),
    freshAuthMaxAgeMs: 5 * 60_000,
  }));
  const server = createServer(app);
  servers.push(server);
  await new Promise<void>((resolve) => server.listen(0, '127.0.0.1', resolve));
  const address = server.address();
  assert(address && typeof address !== 'string');
  return { baseUrl: `http://127.0.0.1:${address.port}`, service, store, now };
}

function keyPair() {
  return generateKeyPairSync('ed25519');
}

function p256KeyPair() {
  return generateKeyPairSync('ec', { namedCurve: 'prime256v1' });
}

async function post(baseUrl: string, path: string, body: unknown) {
  return fetch(`${baseUrl}${path}`, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify(body),
  });
}

async function challenge(baseUrl: string, purpose: 'enrollment' | 'ticket', deviceId?: string) {
  const response = await post(baseUrl, '/api/devices/challenges', {
    purpose,
    device_id: deviceId,
  });
  assert.equal(response.status, 201);
  return response.json() as Promise<{ challenge_id: string; nonce: string; expires_at: string }>;
}

async function enroll(
  baseUrl: string,
  keys = keyPair(),
  replacementDeviceId?: string,
) {
  const issued = await challenge(baseUrl, 'enrollment');
  const publicKey = keys.publicKey.export({ type: 'spki', format: 'pem' }).toString();
  const signature = sign(
    null,
    Buffer.from(deviceChallengeMessage({
      purpose: 'enrollment',
      challengeId: issued.challenge_id,
      nonce: issued.nonce,
      userId: 'user-a',
    })),
    keys.privateKey,
  ).toString('base64url');
  const response = await post(baseUrl, '/api/devices/enroll', {
    challenge_id: issued.challenge_id,
    display_name: 'Test Mac',
    public_key: { algorithm: 'Ed25519', format: 'spki-pem', value: publicKey },
    signature,
    replacement_device_id: replacementDeviceId,
  });
  return { response, keys };
}

test('fresh authentication and signed proof enroll one validated Ed25519 key', async () => {
  const { baseUrl } = await fixture();
  const { response } = await enroll(baseUrl);
  assert.equal(response.status, 201);
  const body = await response.json() as { device: { id: string; status: string; key_algorithm: string } };
  assert.match(body.device.id, /^[0-9a-f-]{36}$/);
  assert.equal(body.device.status, 'active');
  assert.equal(body.device.key_algorithm, 'Ed25519');
});

test('fresh authentication and SHA-256 ECDSA proof enroll one P-256 key', async () => {
  const { baseUrl } = await fixture();
  const issued = await challenge(baseUrl, 'enrollment');
  const keys = p256KeyPair();
  const publicKey = keys.publicKey.export({ type: 'spki', format: 'pem' }).toString();
  const signature = sign(
    'sha256',
    Buffer.from(deviceChallengeMessage({
      purpose: 'enrollment',
      challengeId: issued.challenge_id,
      nonce: issued.nonce,
      userId: 'user-a',
    })),
    keys.privateKey,
  ).toString('base64url');
  const response = await post(baseUrl, '/api/devices/enroll', {
    challenge_id: issued.challenge_id,
    display_name: 'Secure Enclave Mac',
    public_key: { algorithm: 'P-256', format: 'spki-pem', value: publicKey },
    signature,
  });
  assert.equal(response.status, 201);
  const body = await response.json() as { device: { id: string; key_algorithm: string } };
  assert.equal(body.device.key_algorithm, 'P-256');
  const ticketChallenge = await challenge(baseUrl, 'ticket', body.device.id);
  const ticketSignature = sign(
    'sha256',
    Buffer.from(deviceChallengeMessage({
      purpose: 'ticket',
      challengeId: ticketChallenge.challenge_id,
      nonce: ticketChallenge.nonce,
      userId: 'user-a',
      deviceId: body.device.id,
    })),
    keys.privateKey,
  ).toString('base64url');
  const ticket = await post(baseUrl, `/api/devices/${body.device.id}/tickets`, {
    challenge_id: ticketChallenge.challenge_id,
    signature: ticketSignature,
    protocol_versions: [1],
  });
  assert.equal(ticket.status, 201);
});

test('enrollment rejects algorithm confusion and malformed P-256 keys and signatures', async () => {
  const { baseUrl } = await fixture();
  const p256 = p256KeyPair();
  const ed25519 = keyPair();

  for (const publicKey of [
    {
      algorithm: 'Ed25519',
      value: p256.publicKey.export({ type: 'spki', format: 'pem' }).toString(),
    },
    {
      algorithm: 'P-256',
      value: ed25519.publicKey.export({ type: 'spki', format: 'pem' }).toString(),
    },
    {
      algorithm: 'P-256',
      value: '-----BEGIN PUBLIC KEY-----\nAAAA\n-----END PUBLIC KEY-----\n',
    },
  ]) {
    const issued = await challenge(baseUrl, 'enrollment');
    const response = await post(baseUrl, '/api/devices/enroll', {
      challenge_id: issued.challenge_id,
      display_name: 'Confused Mac',
      public_key: { ...publicKey, format: 'spki-pem' },
      signature: Buffer.alloc(64).toString('base64url'),
    });
    assert.equal(response.status, 400);
  }

  const issued = await challenge(baseUrl, 'enrollment');
  const malformedSignature = await post(baseUrl, '/api/devices/enroll', {
    challenge_id: issued.challenge_id,
    display_name: 'Malformed Signature Mac',
    public_key: {
      algorithm: 'P-256',
      format: 'spki-pem',
      value: p256.publicKey.export({ type: 'spki', format: 'pem' }).toString(),
    },
    signature: Buffer.from('not-a-der-signature').toString('base64url'),
  });
  assert.equal(malformedSignature.status, 401);
});

test('enrollment rejects stale account authentication and invalid key proof', async () => {
  const stale = await fixture({ issuedAt: Date.now() - 10 * 60_000 });
  const deniedChallenge = await post(stale.baseUrl, '/api/devices/challenges', { purpose: 'enrollment' });
  assert.equal(deniedChallenge.status, 401);

  const fresh = await fixture();
  const issued = await challenge(fresh.baseUrl, 'enrollment');
  const keys = keyPair();
  const publicKey = keys.publicKey.export({ type: 'spki', format: 'pem' }).toString();
  const deniedProof = await post(fresh.baseUrl, '/api/devices/enroll', {
    challenge_id: issued.challenge_id,
    display_name: 'Forged Mac',
    public_key: { algorithm: 'Ed25519', format: 'spki-pem', value: publicKey },
    signature: Buffer.alloc(64).toString('base64url'),
  });
  assert.equal(deniedProof.status, 401);
});

test('duplicate keys, device exhaustion, and atomic replacement preserve one binding', async () => {
  const { baseUrl, store } = await fixture({ maxDevices: 1 });
  const first = await enroll(baseUrl);
  assert.equal(first.response.status, 201);
  const firstDevice = (await first.response.json() as { device: { id: string } }).device;

  const duplicate = await enroll(baseUrl, first.keys);
  assert.equal(duplicate.response.status, 409);

  const exhausted = await enroll(baseUrl);
  assert.equal(exhausted.response.status, 409);

  const replacement = await enroll(baseUrl, keyPair(), firstDevice.id);
  assert.equal(replacement.response.status, 201);
  const replacementId = (await replacement.response.json() as { device: { id: string } }).device.id;
  assert.equal((await store.getDevice('user-a', firstDevice.id))?.status, 'revoked');
  assert.equal((await store.getDevice('user-a', replacementId))?.status, 'active');
});

test('ticket issuance requires the enrolled device proof and negotiates a protocol', async () => {
  const { baseUrl, service } = await fixture();
  const enrolled = await enroll(baseUrl);
  const device = (await enrolled.response.json() as { device: { id: string } }).device;
  await assert.rejects(
    service.createChallenge('user-b', 'ticket', device.id),
    /Active device not found/,
  );
  const issued = await challenge(baseUrl, 'ticket', device.id);
  const forged = await post(baseUrl, `/api/devices/${device.id}/tickets`, {
    challenge_id: issued.challenge_id,
    signature: Buffer.alloc(64).toString('base64url'),
    protocol_versions: [1],
  });
  assert.equal(forged.status, 401);
  const signature = sign(
    null,
    Buffer.from(deviceChallengeMessage({
      purpose: 'ticket',
      challengeId: issued.challenge_id,
      nonce: issued.nonce,
      userId: 'user-a',
      deviceId: device.id,
    })),
    enrolled.keys.privateKey,
  ).toString('base64url');
  const response = await post(baseUrl, `/api/devices/${device.id}/tickets`, {
    challenge_id: issued.challenge_id,
    signature,
    protocol_versions: [1],
  });
  assert.equal(response.status, 201);
  const body = await response.json() as { ticket: string; protocol_version: number };
  assert.equal(body.protocol_version, 1);
  assert.equal(body.ticket.split('.').length, 3);
});

test('device revocation and logout fencing are owner-scoped hooks', async () => {
  const { baseUrl, store } = await fixture();
  const enrolled = await enroll(baseUrl);
  const device = (await enrolled.response.json() as { device: { id: string } }).device;
  const revoked = await fetch(`${baseUrl}/api/devices/${device.id}`, { method: 'DELETE' });
  assert.equal(revoked.status, 204);
  assert.equal((await store.getDevice('user-a', device.id))?.status, 'revoked');

  const logout = await post(baseUrl, '/api/devices/logout', {});
  assert.equal(logout.status, 204);
});
