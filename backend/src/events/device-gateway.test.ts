import { generateKeyPairSync, sign } from 'node:crypto';
import { createServer } from 'node:http';
import assert from 'node:assert/strict';
import { afterEach, test } from 'node:test';
import { WebSocket } from 'ws';
import {
  DeviceService,
  InMemoryDeviceStore,
  deviceChallengeMessage,
} from '../devices/device-service.ts';
import { DeviceGateway, type DeviceGatewayMessage } from './device-gateway.ts';

const cleanups: Array<() => Promise<void>> = [];
afterEach(async () => {
  await Promise.all(cleanups.splice(0).map((cleanup) => cleanup()));
});

async function fixture(overrides: Partial<ConstructorParameters<typeof DeviceGateway>[1]> = {}) {
  const now = { value: Date.now() };
  const store = new InMemoryDeviceStore(() => now.value);
  const service = new DeviceService(store, {
    signingSecret: 'test-ticket-secret-that-is-at-least-32-bytes',
    issuer: 'https://api.example.test',
    audience: 'wss://api.example.test/api/device-gateway',
    challengeTtlMs: 60_000,
    ticketTtlMs: 30_000,
    maxDevicesPerUser: 2,
    supportedProtocolVersions: [1],
    now: () => now.value,
  });
  const messages: Array<{ fence: number; message: DeviceGatewayMessage }> = [];
  const gateway = new DeviceGateway(service, {
    path: '/api/device-gateway',
    allowedOrigins: ['perch://app'],
    supportedProtocolVersions: [1],
    maxPayloadBytes: 1_024,
    maxMessagesPerWindow: 3,
    maxBytesPerWindow: 2_048,
    rateWindowMs: 60_000,
    maxConnectionBytes: 8_192,
    maxBufferedBytes: 1_024,
    heartbeatIntervalMs: 60_000,
    heartbeatTimeoutMs: 120_000,
    handshakeTimeoutMs: 2_000,
    ...overrides,
  }, {
    onMessage: async (identity, message) => {
      messages.push({ fence: identity.fence, message });
    },
  });
  const server = createServer();
  gateway.attach(server);
  await new Promise<void>((resolve) => server.listen(0, '127.0.0.1', resolve));
  const address = server.address();
  assert(address && typeof address !== 'string');
  const url = `ws://127.0.0.1:${address.port}/api/device-gateway`;
  cleanups.push(async () => {
    await gateway.close();
    await new Promise<void>((resolve) => server.close(() => resolve()));
  });

  const keys = generateKeyPairSync('ed25519');
  const enrollment = await service.createChallenge('user-a', 'enrollment');
  const publicKey = keys.publicKey.export({ type: 'spki', format: 'pem' }).toString();
  const enrolled = await service.enroll({
    userId: 'user-a',
    challengeId: enrollment.id,
    displayName: 'Gateway Mac',
    publicKey: { algorithm: 'Ed25519', format: 'spki-pem', value: publicKey },
    signature: sign(
      null,
      Buffer.from(deviceChallengeMessage({
        purpose: 'enrollment',
        challengeId: enrollment.id,
        nonce: enrollment.nonce,
        userId: 'user-a',
      })),
      keys.privateKey,
    ).toString('base64url'),
  });

  async function ticket() {
    const challenge = await service.createChallenge('user-a', 'ticket', enrolled.id);
    return service.issueTicket({
      userId: 'user-a',
      deviceId: enrolled.id,
      challengeId: challenge.id,
      protocolVersions: [1],
      signature: sign(
        null,
        Buffer.from(deviceChallengeMessage({
          purpose: 'ticket',
          challengeId: challenge.id,
          nonce: challenge.nonce,
          userId: 'user-a',
          deviceId: enrolled.id,
        })),
        keys.privateKey,
      ).toString('base64url'),
    });
  }

  return { service, store, gateway, url, now, enrolled, ticket, messages };
}

function connect(url: string, ticket: string, options: {
  origin?: string;
  protocols?: string[];
  authorization?: string | null;
} = {}) {
  const authorization = options.authorization === undefined ? `Bearer ${ticket}` : options.authorization;
  return new WebSocket(url, options.protocols ?? ['perch.v1'], {
    origin: options.origin ?? 'perch://app',
    headers: authorization ? { Authorization: authorization } : {},
  });
}

function opened(ws: WebSocket): Promise<void> {
  return new Promise((resolve, reject) => {
    ws.once('open', resolve);
    ws.once('error', reject);
  });
}

function closed(ws: WebSocket): Promise<number> {
  return new Promise((resolve) => ws.once('close', (code) => resolve(code)));
}

test('one-use header ticket authenticates identity and replay is rejected', async () => {
  const { url, ticket } = await fixture();
  const issued = await ticket();
  const first = connect(url, issued.ticket);
  await opened(first);
  assert.equal(first.protocol, 'perch.v1');

  const replay = connect(url, issued.ticket);
  await assert.rejects(opened(replay));
});

test('a ticket may use the WebSocket protocol header but never exposes itself as selected protocol', async () => {
  const { url, ticket } = await fixture();
  const issued = await ticket();
  const encoded = Buffer.from(issued.ticket).toString('base64url');
  const socket = connect(url, issued.ticket, {
    authorization: null,
    protocols: ['perch.v1', `perch-ticket.${encoded}`],
  });
  await opened(socket);
  assert.equal(socket.protocol, 'perch.v1');
});

test('ticket is never accepted in query and unsigned, expired, or revoked credentials fail', async () => {
  const { url, ticket, now, service, enrolled } = await fixture();
  const queryTicket = await ticket();
  const query = connect(`${url}?ticket=${encodeURIComponent(queryTicket.ticket)}`, queryTicket.ticket);
  await assert.rejects(opened(query));

  const unsigned = connect(url, 'eyJhbGciOiJub25lIn0.eyJzdWIiOiJ1c2VyLWEifQ.');
  await assert.rejects(opened(unsigned));

  const expiredTicket = await ticket();
  now.value += 31_000;
  const expired = connect(url, expiredTicket.ticket);
  await assert.rejects(opened(expired));

  now.value -= 31_000;
  const revokedTicket = await ticket();
  await service.revokeDevice('user-a', enrolled.id);
  const revoked = connect(url, revokedTicket.ticket);
  await assert.rejects(opened(revoked));
});

test('a newer fence closes the old socket and only current-fence messages reach handlers', async () => {
  const { url, ticket, messages } = await fixture();
  const firstTicket = await ticket();
  const first = connect(url, firstTicket.ticket);
  await opened(first);
  const firstClosed = closed(first);

  const secondTicket = await ticket();
  const second = connect(url, secondTicket.ticket);
  await opened(second);
  assert.equal(await firstClosed, 4002);

  first.send(JSON.stringify({
    v: 1,
    type: 'ack',
    id: '10000000-0000-4000-8000-000000000001',
    payload: {},
  }), () => {});
  second.send(JSON.stringify({
    v: 1,
    type: 'ack',
    id: '20000000-0000-4000-8000-000000000002',
    payload: {},
  }));
  await new Promise((resolve) => setTimeout(resolve, 20));
  assert.deepEqual(
    messages.map(({ message }) => message.id),
    ['20000000-0000-4000-8000-000000000002'],
  );
});

test('origin, protocol, malformed, oversized, and flooded clients are isolated', async () => {
  const fixtureValue = await fixture({ maxMessagesPerWindow: 2, maxPayloadBytes: 128 });
  const badOriginTicket = await fixtureValue.ticket();
  const badOrigin = connect(fixtureValue.url, badOriginTicket.ticket, { origin: 'https://evil.example' });
  await assert.rejects(opened(badOrigin));

  const badProtocolTicket = await fixtureValue.ticket();
  const badProtocol = connect(fixtureValue.url, badProtocolTicket.ticket, { protocols: ['perch.v999'] });
  await assert.rejects(opened(badProtocol));

  const malformedTicket = await fixtureValue.ticket();
  const malformed = connect(fixtureValue.url, malformedTicket.ticket);
  await opened(malformed);
  const malformedClosed = closed(malformed);
  malformed.send('{');
  assert.equal(await malformedClosed, 4004);

  const oversizedTicket = await fixtureValue.ticket();
  const oversized = connect(fixtureValue.url, oversizedTicket.ticket);
  await opened(oversized);
  const oversizedClosed = closed(oversized);
  oversized.send('x'.repeat(256));
  assert.notEqual(await oversizedClosed, 1000);

  const floodTicket = await fixtureValue.ticket();
  const flood = connect(fixtureValue.url, floodTicket.ticket);
  await opened(flood);
  const floodClosed = closed(flood);
  flood.send(JSON.stringify({
    v: 1,
    type: 'ack',
    id: '10000000-0000-4000-8000-000000000001',
    payload: {},
  }));
  flood.send(JSON.stringify({
    v: 1,
    type: 'ack',
    id: '20000000-0000-4000-8000-000000000002',
    payload: {},
  }));
  flood.send(JSON.stringify({
    v: 1,
    type: 'ack',
    id: '30000000-0000-4000-8000-000000000003',
    payload: {},
  }));
  assert.equal(await floodClosed, 4005);
});

test('unsupported message versions and pending-byte backpressure close only that socket', async () => {
  const unsupportedFixture = await fixture();
  const unsupportedTicket = await unsupportedFixture.ticket();
  const unsupported = connect(unsupportedFixture.url, unsupportedTicket.ticket);
  await opened(unsupported);
  const unsupportedClosed = closed(unsupported);
  unsupported.send(JSON.stringify({
    v: 999,
    type: 'ack',
    id: '10000000-0000-4000-8000-000000000001',
    payload: {},
  }));
  assert.equal(await unsupportedClosed, 4003);

  const pressuredFixture = await fixture({ maxBufferedBytes: 16 });
  const pressuredTicket = await pressuredFixture.ticket();
  const pressured = connect(pressuredFixture.url, pressuredTicket.ticket);
  await opened(pressured);
  const pressuredClosed = closed(pressured);
  pressured.send(JSON.stringify({
    v: 1,
    type: 'ack',
    id: '10000000-0000-4000-8000-000000000001',
    payload: {},
  }));
  assert.equal(await pressuredClosed, 4007);
});
