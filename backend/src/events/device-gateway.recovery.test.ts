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
import {
  DeviceGateway,
  type DeviceGatewayHandler,
  type DeviceGatewayOutboundMessage,
} from './device-gateway.ts';

const cleanups: Array<() => Promise<void>> = [];
afterEach(async () => {
  await Promise.all(cleanups.splice(0).map((cleanup) => cleanup()));
});

async function deviceFixture(handler: DeviceGatewayHandler) {
  const store = new InMemoryDeviceStore();
  const service = new DeviceService(store, {
    signingSecret: 'recovery-test-secret-that-is-at-least-32-bytes',
    issuer: 'https://api.example.test',
    audience: 'wss://api.example.test/api/device-gateway',
    challengeTtlMs: 60_000,
    ticketTtlMs: 30_000,
    maxDevicesPerUser: 2,
    supportedProtocolVersions: [1],
  });
  const keys = generateKeyPairSync('ed25519');
  const challenge = await service.createChallenge('user-a', 'enrollment');
  const enrolled = await service.enroll({
    userId: 'user-a',
    challengeId: challenge.id,
    displayName: 'Recovery Mac',
    publicKey: {
      algorithm: 'Ed25519',
      format: 'spki-pem',
      value: keys.publicKey.export({ type: 'spki', format: 'pem' }).toString(),
    },
    signature: sign(null, Buffer.from(deviceChallengeMessage({
      purpose: 'enrollment',
      challengeId: challenge.id,
      nonce: challenge.nonce,
      userId: 'user-a',
    })), keys.privateKey).toString('base64url'),
  });

  async function ticket() {
    const issued = await service.createChallenge('user-a', 'ticket', enrolled.id);
    return service.issueTicket({
      userId: 'user-a',
      deviceId: enrolled.id,
      challengeId: issued.id,
      protocolVersions: [1],
      signature: sign(null, Buffer.from(deviceChallengeMessage({
        purpose: 'ticket',
        challengeId: issued.id,
        nonce: issued.nonce,
        userId: 'user-a',
        deviceId: enrolled.id,
      })), keys.privateKey).toString('base64url'),
    });
  }

  async function start() {
    const gateway = new DeviceGateway(service, {
      path: '/api/device-gateway',
      allowedOrigins: ['perch://app'],
      supportedProtocolVersions: [1],
      maxPayloadBytes: 16 * 1024,
      maxMessagesPerWindow: 100,
      maxBytesPerWindow: 128 * 1024,
      rateWindowMs: 60_000,
      maxConnectionBytes: 1024 * 1024,
      maxBufferedBytes: 128 * 1024,
      heartbeatIntervalMs: 60_000,
      heartbeatTimeoutMs: 120_000,
      handshakeTimeoutMs: 2_000,
    }, handler);
    const server = createServer();
    gateway.attach(server);
    await new Promise<void>((resolve) => server.listen(0, '127.0.0.1', resolve));
    const address = server.address();
    assert(address && typeof address !== 'string');
    const close = async () => {
      await gateway.close();
      await new Promise<void>((resolve) => server.close(() => resolve()));
    };
    cleanups.push(close);
    return {
      url: `ws://127.0.0.1:${address.port}/api/device-gateway`,
      close,
    };
  }
  return { ticket, start };
}

async function connect(url: string, ticket: string): Promise<WebSocket> {
  const socket = new WebSocket(url, ['perch.v1'], {
    origin: 'perch://app',
    headers: { authorization: `Bearer ${ticket}` },
  });
  await new Promise<void>((resolve, reject) => {
    socket.once('open', resolve);
    socket.once('error', reject);
  });
  return socket;
}

function nextMessage(socket: WebSocket): Promise<DeviceGatewayOutboundMessage> {
  return new Promise((resolve, reject) => {
    socket.once('message', (data) => resolve(JSON.parse(data.toString())));
    socket.once('error', reject);
  });
}

test('unacknowledged events replay after disconnect and gateway restart', async () => {
  let cursor = 0;
  const event: DeviceGatewayOutboundMessage = {
    v: 1,
    type: 'event',
    id: '30000000-0000-4000-8000-000000000003',
    payload: { sequence: 1, transition_id: 't-1', event_type: 'local_action_offered' },
  };
  const handler: DeviceGatewayHandler = {
    async onConnect() {
      await new Promise((resolve) => setTimeout(resolve, 5));
      return cursor < 1 ? [event] : [];
    },
    async onMessage(_identity, message) {
      if (message.type === 'ack') cursor = Number(message.payload.sequence);
    },
  };
  const fixture = await deviceFixture(handler);
  const firstGateway = await fixture.start();
  const first = await connect(firstGateway.url, (await fixture.ticket()).ticket);
  assert.equal((await nextMessage(first)).id, event.id);
  first.terminate();
  await firstGateway.close();
  cleanups.pop();

  const restarted = await fixture.start();
  const second = await connect(restarted.url, (await fixture.ticket()).ticket);
  assert.equal((await nextMessage(second)).id, event.id);
  second.send(JSON.stringify({
    v: 1,
    type: 'ack',
    id: '40000000-0000-4000-8000-000000000004',
    payload: { event_id: event.id, sequence: 1 },
  }));
  await new Promise((resolve) => setTimeout(resolve, 20));
  second.close();

  const third = await connect(restarted.url, (await fixture.ticket()).ticket);
  const unexpected = Promise.race([
    nextMessage(third).then(() => true),
    new Promise<false>((resolve) => setTimeout(() => resolve(false), 30)),
  ]);
  assert.equal(await unexpected, false);
});

test('approval committed before delivery replays the same durable grant after disconnect', async () => {
  let grant: DeviceGatewayOutboundMessage | null = null;
  let failAfterCommit = true;
  const handler: DeviceGatewayHandler = {
    async onConnect() {
      await new Promise((resolve) => setTimeout(resolve, 5));
      return grant ? [grant] : [];
    },
    async onMessage(_identity, message) {
      if (message.type === 'action_decision') {
        grant = {
          v: 1,
          type: 'execution_grant',
          id: '50000000-0000-4000-8000-000000000005',
          payload: {
            transition_id: message.id,
            action_hash: 'a'.repeat(64),
            parameters_hash: 'b'.repeat(64),
          },
        };
        if (failAfterCommit) {
          failAfterCommit = false;
          throw new Error('disconnect after atomic commit');
        }
        return [grant];
      }
    },
  };
  const fixture = await deviceFixture(handler);
  const running = await fixture.start();
  const first = await connect(running.url, (await fixture.ticket()).ticket);
  const closed = new Promise<number>((resolve) => first.once('close', resolve));
  first.send(JSON.stringify({
    v: 1,
    type: 'action_decision',
    id: '60000000-0000-4000-8000-000000000006',
    payload: {},
  }));
  assert.equal(await closed, 1011);

  const second = await connect(running.url, (await fixture.ticket()).ticket);
  const replayed = await nextMessage(second);
  assert.equal(replayed.type, 'execution_grant');
  assert.equal(replayed.id, grant!.id);
});

test('replay quota outage closes recovery instead of opening an empty session', async () => {
  const handler: DeviceGatewayHandler = {
    async onConnect() {
      await new Promise((resolve) => setTimeout(resolve, 5));
      throw new Error('distributed quota unavailable');
    },
    async onMessage() {},
  };
  const fixture = await deviceFixture(handler);
  const running = await fixture.start();
  const socket = await connect(running.url, (await fixture.ticket()).ticket);
  const code = await new Promise<number>((resolve) => socket.once('close', resolve));
  assert.equal(code, 1013);
});
