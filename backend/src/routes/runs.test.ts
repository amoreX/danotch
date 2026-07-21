import { createServer } from 'node:http';
import assert from 'node:assert/strict';
import { afterEach, test } from 'node:test';
import express, { type RequestHandler } from 'express';
import type { RunRouteStore } from './runs.ts';
import type { DurableRunRecord } from '../protocol/durable-run-store.ts';

process.env.SUPABASE_URL ??= 'http://127.0.0.1:54321';
process.env.SUPABASE_PUBLISHABLE_KEY ??= 'test-publishable-key';
const { createRunRoutes } = await import('./runs.ts');

const runId = '10000000-0000-4000-8000-000000000001';
const deviceId = '20000000-0000-4000-8000-000000000002';
const servers: Array<ReturnType<typeof createServer>> = [];
afterEach(async () => {
  await Promise.all(servers.splice(0).map((server) =>
    new Promise<void>((resolve) => server.close(() => resolve()))));
});

function run(ownerId = 'owner-a'): DurableRunRecord {
  return {
    id: runId,
    userId: ownerId,
    deviceId,
    state: 'waiting_for_device',
    revision: 1,
    input: {},
    checkpoint: null,
    terminalCode: null,
    terminalResult: null,
    createdAt: '2026-07-21T00:00:00.000Z',
    updatedAt: '2026-07-21T00:00:00.000Z',
    terminalAt: null,
  };
}

async function fixture(store: RunRouteStore, ownerId = 'owner-a') {
  const auth: RequestHandler = (req, _res, next) => {
    req.user = {
      sub: ownerId,
      email: `${ownerId}@example.test`,
      role: 'authenticated',
      authTime: Date.now(),
    };
    next();
  };
  const app = express();
  app.use(express.json());
  app.use('/api/runs', createRunRoutes({ requireAuth: auth, store }));
  const server = createServer(app);
  servers.push(server);
  await new Promise<void>((resolve) => server.listen(0, '127.0.0.1', resolve));
  const address = server.address();
  assert(address && typeof address !== 'string');
  return `http://127.0.0.1:${address.port}`;
}

test('run list/get and snapshots remain owner scoped', async () => {
  const owners: string[] = [];
  const store: RunRouteStore = {
    async list(ownerId) {
      owners.push(ownerId);
      return [run(ownerId)];
    },
    async get(ownerId, id) {
      owners.push(ownerId);
      return id === runId ? run(ownerId) : null;
    },
    async cancel() {
      throw new Error('not used');
    },
    async snapshot(ownerId, id) {
      owners.push(ownerId);
      return id === deviceId
        ? { device: { id }, cursor: 8, runs: [], actions: [], grants: [] }
        : null;
    },
  };
  const baseUrl = await fixture(store);
  assert.equal((await fetch(`${baseUrl}/api/runs`)).status, 200);
  assert.equal((await fetch(`${baseUrl}/api/runs/${runId}`)).status, 200);
  const snapshot = await fetch(`${baseUrl}/api/runs/devices/${deviceId}/snapshot`);
  assert.equal(snapshot.status, 200);
  assert.equal((await snapshot.json() as { cursor: number }).cursor, 8);
  assert.deepEqual(owners, ['owner-a', 'owner-a', 'owner-a']);
});

test('explicit cancellation is idempotently delegated with authenticated owner', async () => {
  const cancellations: Array<Record<string, string>> = [];
  const store: RunRouteStore = {
    async list() { return []; },
    async get() { return null; },
    async snapshot() { return null; },
    async cancel(ownerId, id, reason) {
      cancellations.push({ ownerId, id, reason });
      return { ...run(ownerId), state: 'cancellation_requested' };
    },
  };
  const baseUrl = await fixture(store);
  const response = await fetch(`${baseUrl}/api/runs/${runId}/cancel`, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ reason: 'user requested' }),
  });
  assert.equal(response.status, 200);
  assert.deepEqual(cancellations, [{
    ownerId: 'owner-a',
    id: runId,
    reason: 'user requested',
  }]);
});

test('snapshot and run lookup do not reveal a missing foreign-owner resource', async () => {
  const store: RunRouteStore = {
    async list() { return []; },
    async get() { return null; },
    async cancel() { throw new Error('not found'); },
    async snapshot() { return null; },
  };
  const baseUrl = await fixture(store, 'owner-b');
  assert.equal((await fetch(`${baseUrl}/api/runs/${runId}`)).status, 404);
  assert.equal(
    (await fetch(`${baseUrl}/api/runs/devices/${deviceId}/snapshot`)).status,
    404,
  );
});
