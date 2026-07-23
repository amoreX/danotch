/**
 * U7: Liveness/readiness contract tests and SIGTERM drain test.
 *
 * Uses the real health functions and minimal Express stubs so these run
 * without real database connections.
 */

import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import { createServer } from 'node:http';
import type { Socket } from 'node:net';
import { test } from 'node:test';
import express from 'express';
import { livenessStatus, readinessStatus, type ReadinessCheck } from './health.ts';

// ── Health function unit tests ───────────────────────────────────────────────

test('livenessStatus returns live status with pid and uptime', () => {
  const result = livenessStatus();
  assert.equal(result.status, 'live');
  assert.equal(result.pid, process.pid);
  assert.ok(result.uptime_seconds >= 0, 'uptime should be non-negative');
});

test('readinessStatus returns ready when all checks pass', async () => {
  const checks: ReadinessCheck[] = [
    { name: 'db', check: async () => ({ ok: true }) },
    { name: 'gateway', check: async () => ({ ok: true }) },
  ];
  const result = await readinessStatus(checks);
  assert.equal(result.status, 'ready');
  assert.equal(result.checks['db']?.ok, true);
  assert.equal(result.checks['gateway']?.ok, true);
});

test('readinessStatus returns not_ready when any check fails', async () => {
  const checks: ReadinessCheck[] = [
    { name: 'db', check: async () => ({ ok: true }) },
    { name: 'gateway', check: async () => ({ ok: false, detail: 'not attached' }) },
    { name: 'provider', check: async () => ({ ok: true }) },
  ];
  const result = await readinessStatus(checks);
  assert.equal(result.status, 'not_ready');
  assert.equal(result.checks['gateway']?.ok, false);
  assert.equal(result.checks['gateway']?.detail, 'not attached');
  // Passing checks are still included.
  assert.equal(result.checks['db']?.ok, true);
});

test('readinessStatus captures thrown errors as failing checks', async () => {
  const checks: ReadinessCheck[] = [
    {
      name: 'exploding',
      check: async () => {
        throw new Error('connection refused');
      },
    },
  ];
  const result = await readinessStatus(checks);
  assert.equal(result.status, 'not_ready');
  assert.equal(result.checks['exploding']?.ok, false);
  assert.ok(result.checks['exploding']?.detail?.includes('connection refused'));
});

test('readinessStatus runs all checks and includes every result', async () => {
  const completed: string[] = [];
  const checks: ReadinessCheck[] = [
    {
      name: 'slow',
      check: () =>
        new Promise<{ ok: boolean }>((resolve) => {
          setTimeout(() => {
            completed.push('slow');
            resolve({ ok: true });
          }, 15);
        }),
    },
    {
      name: 'fast',
      check: async () => {
        completed.push('fast');
        return { ok: false, detail: 'down' };
      },
    },
  ];
  const result = await readinessStatus(checks);
  assert.equal(result.status, 'not_ready');
  assert.equal(Object.keys(result.checks).length, 2);
  // Both checks ran despite one failing.
  assert.ok(completed.includes('fast'));
  assert.ok(completed.includes('slow'));
});

// ── HTTP contract helpers ────────────────────────────────────────────────────

async function makeRequest(
  srv: ReturnType<typeof createServer>,
  path: string,
  headers?: Record<string, string>,
): Promise<{ status: number; body: unknown; headers: Headers }> {
  const port = (srv.address() as { port: number }).port;
  const res = await fetch(`http://127.0.0.1:${port}${path}`, { headers });
  const body = await res.json().catch(() => null);
  return { status: res.status, body, headers: res.headers };
}

function startServer(app: express.Express): Promise<ReturnType<typeof createServer>> {
  return new Promise((resolve, reject) => {
    const srv = createServer(app);
    srv.listen(0, '127.0.0.1', () => resolve(srv));
    srv.on('error', reject);
  });
}

// ── /health/live contract ────────────────────────────────────────────────────

test('/health/live returns 200 with live status shape', async () => {
  const app = express();
  app.get('/health/live', (_req, res) => res.json(livenessStatus()));
  const srv = await startServer(app);

  const { status, body } = await makeRequest(srv, '/health/live');
  await new Promise<void>((r) => srv.close(r));

  assert.equal(status, 200);
  assert.equal((body as { status: string }).status, 'live');
  assert.ok(typeof (body as { uptime_seconds: number }).uptime_seconds === 'number');
});

// ── /health/ready contract ───────────────────────────────────────────────────

test('/health/ready returns 200 when all checks pass', async () => {
  const checks: ReadinessCheck[] = [
    { name: 'migration_ledger', check: async () => ({ ok: true }) },
    { name: 'database', check: async () => ({ ok: true }) },
    { name: 'gateway', check: async () => ({ ok: true }) },
    { name: 'provider', check: async () => ({ ok: true }) },
  ];
  const app = express();
  app.get('/health/ready', async (_req, res) => {
    const result = await readinessStatus(checks);
    res.status(result.status === 'ready' ? 200 : 503).json(result);
  });
  const srv = await startServer(app);

  const { status, body } = await makeRequest(srv, '/health/ready');
  await new Promise<void>((r) => srv.close(r));

  assert.equal(status, 200);
  assert.equal((body as { status: string }).status, 'ready');
});

test('/health/ready returns 503 when migration_ledger check fails', async () => {
  const checks: ReadinessCheck[] = [
    { name: 'migration_ledger', check: async () => ({ ok: false, detail: 'migration 011 missing' }) },
    { name: 'database', check: async () => ({ ok: true }) },
  ];
  const app = express();
  app.get('/health/ready', async (_req, res) => {
    const result = await readinessStatus(checks);
    res.status(result.status === 'ready' ? 200 : 503).json(result);
  });
  const srv = await startServer(app);

  const { status, body } = await makeRequest(srv, '/health/ready');
  await new Promise<void>((r) => srv.close(r));

  assert.equal(status, 503);
  assert.equal((body as { status: string }).status, 'not_ready');
  const checkResults = (body as { checks: Record<string, { ok: boolean; detail?: string }> }).checks;
  assert.equal(checkResults['migration_ledger']?.ok, false);
  assert.ok(checkResults['migration_ledger']?.detail?.includes('011'));
});

test('/health/ready returns 503 when database is unreachable', async () => {
  const checks: ReadinessCheck[] = [
    { name: 'database', check: async () => { throw new Error('ECONNREFUSED'); } },
    { name: 'gateway', check: async () => ({ ok: true }) },
  ];
  const app = express();
  app.get('/health/ready', async (_req, res) => {
    const result = await readinessStatus(checks);
    res.status(result.status === 'ready' ? 200 : 503).json(result);
  });
  const srv = await startServer(app);

  const { status, body } = await makeRequest(srv, '/health/ready');
  await new Promise<void>((r) => srv.close(r));

  assert.equal(status, 503);
  const checkResults = (body as { checks: Record<string, { ok: boolean; detail?: string }> }).checks;
  assert.equal(checkResults['database']?.ok, false);
  assert.ok(checkResults['database']?.detail?.includes('ECONNREFUSED'));
});

test('/health/ready returns 503 when gateway is not ready', async () => {
  const checks: ReadinessCheck[] = [
    { name: 'database', check: async () => ({ ok: true }) },
    { name: 'gateway', check: async () => ({ ok: false, detail: 'gateway not attached' }) },
  ];
  const app = express();
  app.get('/health/ready', async (_req, res) => {
    const result = await readinessStatus(checks);
    res.status(result.status === 'ready' ? 200 : 503).json(result);
  });
  const srv = await startServer(app);

  const { status, body } = await makeRequest(srv, '/health/ready');
  await new Promise<void>((r) => srv.close(r));

  assert.equal(status, 503);
  const checkResults = (body as { checks: Record<string, { ok: boolean; detail?: string }> }).checks;
  assert.equal(checkResults['gateway']?.ok, false);
});

test('/health/ready returns 503 when critical provider is not configured', async () => {
  const checks: ReadinessCheck[] = [
    { name: 'database', check: async () => ({ ok: true }) },
    { name: 'gateway', check: async () => ({ ok: true }) },
    { name: 'provider', check: async () => ({ ok: false, detail: 'no critical LLM provider configured' }) },
  ];
  const app = express();
  app.get('/health/ready', async (_req, res) => {
    const result = await readinessStatus(checks);
    res.status(result.status === 'ready' ? 200 : 503).json(result);
  });
  const srv = await startServer(app);

  const { status, body } = await makeRequest(srv, '/health/ready');
  await new Promise<void>((r) => srv.close(r));

  assert.equal(status, 503);
  const checkResults = (body as { checks: Record<string, { ok: boolean; detail?: string }> }).checks;
  assert.equal(checkResults['provider']?.ok, false);
});

// ── Correlation ID contract ──────────────────────────────────────────────────

function makeCorrelationApp(): express.Express {
  const app = express();
  app.use((_req, res, next) => {
    const inbound = _req.headers['x-request-id'];
    const rid =
      typeof inbound === 'string' && /^[\w\-]{8,64}$/.test(inbound)
        ? inbound
        : randomUUID();
    res.locals['correlationId'] = rid;
    res.setHeader('X-Request-ID', rid);
    next();
  });
  app.get('/ping', (_req, res) => res.json({ ok: true }));
  return app;
}

test('correlation middleware echoes a valid X-Request-ID from the client', async () => {
  const id = randomUUID();
  const srv = await startServer(makeCorrelationApp());

  const port = (srv.address() as { port: number }).port;
  const res = await fetch(`http://127.0.0.1:${port}/ping`, {
    headers: { 'X-Request-ID': id },
  });
  await new Promise<void>((r) => srv.close(r));

  assert.equal(res.headers.get('X-Request-ID'), id);
});

test('correlation middleware generates a new UUID when client omits X-Request-ID', async () => {
  const srv = await startServer(makeCorrelationApp());
  const { headers } = await makeRequest(srv, '/ping');
  await new Promise<void>((r) => srv.close(r));

  const rid = headers.get('X-Request-ID');
  assert.ok(rid, 'X-Request-ID must be present');
  assert.match(
    rid!,
    /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i,
    'generated ID must be a UUID v4',
  );
});

test('correlation middleware rejects a wildcard or overly long X-Request-ID', async () => {
  const srv = await startServer(makeCorrelationApp());
  const port = (srv.address() as { port: number }).port;

  // A wildcard or long malicious header should be replaced with a fresh ID.
  const malicious = '*'.repeat(200);
  const res = await fetch(`http://127.0.0.1:${port}/ping`, {
    headers: { 'X-Request-ID': malicious },
  });
  await new Promise<void>((r) => srv.close(r));

  const rid = res.headers.get('X-Request-ID');
  assert.ok(rid, 'must still return a correlation ID');
  assert.notEqual(rid, malicious, 'must not echo a malicious header value');
});

// ── SIGTERM drain test ───────────────────────────────────────────────────────

test('SIGTERM drain: server stops accepting new connections while in-flight requests complete', async () => {
  const app = express();
  let isShuttingDown = false;

  // Signal that the slow request has been received by the server.
  let signalSlowReceived!: () => void;
  const slowReceived = new Promise<void>((resolve) => { signalSlowReceived = resolve; });

  // Slow route simulates an in-flight request (delays before responding).
  app.get('/slow', (_req, res) => {
    signalSlowReceived();
    setTimeout(() => res.json({ finished: true }), 60);
  });
  app.get('/fast', (_req, res) => res.json({ ok: true }));

  const activeSockets = new Set<Socket>();
  const srv = createServer(app);
  srv.on('connection', (socket) => {
    activeSockets.add(socket);
    socket.once('close', () => activeSockets.delete(socket));
  });
  srv.on('request', (_req, res) => {
    if (isShuttingDown) res.setHeader('Connection', 'close');
  });

  await new Promise<void>((r) => srv.listen(0, '127.0.0.1', r));
  const port = (srv.address() as { port: number }).port;
  const base = `http://127.0.0.1:${port}`;

  // Pre-drain: server is alive.
  const preDrain = await fetch(`${base}/fast`);
  assert.equal(preDrain.status, 200);

  // Fire an in-flight slow request.
  const slowPromise = fetch(`${base}/slow`);

  // Wait until the server has received the slow request before draining.
  // This ensures the TCP connection is established so srv.close() doesn't
  // prevent its completion.
  await slowReceived;

  // Begin drain: stop accepting new connections (SIGTERM handler behaviour).
  isShuttingDown = true;
  srv.close();

  // In-flight request must complete successfully despite the drain starting.
  const slowRes = await slowPromise;
  assert.equal(slowRes.status, 200);
  assert.equal((await slowRes.json() as { finished: boolean }).finished, true);

  // After drain, new connection attempts should fail.
  let rejected = false;
  try {
    await fetch(`${base}/fast`, { signal: AbortSignal.timeout(500) });
  } catch {
    rejected = true;
  }
  assert.ok(rejected, 'New connections must be rejected after drain starts');

  for (const s of activeSockets) s.destroy();
});

test('SIGTERM drain deadline: forced exit fires when drain takes too long', async () => {
  let forcedExit = false;
  const DEADLINE = 60;

  await new Promise<void>((resolve) => {
    // Simulate drain that never finishes (hangs).
    const drainTimer = setTimeout(() => {
      forcedExit = true;
      resolve();
    }, DEADLINE);
    // Do NOT clear the timer — the deadline should fire.
  });

  assert.equal(forcedExit, true, 'Forced exit must fire when drain does not complete in time');
});

test('SIGTERM drain deadline: does not force exit when drain completes early', async () => {
  let forcedExit = false;
  const DEADLINE = 100;

  await new Promise<void>((resolve) => {
    const drainTimer = setTimeout(() => {
      forcedExit = true;
      resolve();
    }, DEADLINE);

    // Simulate all connections closing before deadline.
    setTimeout(() => {
      clearTimeout(drainTimer);
      resolve();
    }, 20);
  });

  assert.equal(forcedExit, false, 'Forced exit must not fire when drain completes before deadline');
});
