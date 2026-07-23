import 'dotenv/config';
import { createServer, type IncomingMessage, type ServerResponse } from 'node:http';
import type { Socket } from 'node:net';
import { createApp } from './app.js';
import { config } from './config.js';
import { DeviceService } from './devices/device-service.js';
import { SupabaseDeviceStore } from './devices/supabase-device-store.js';
import { DeviceGateway } from './events/device-gateway.js';
import { SupabaseDeviceMessageHandler } from './events/device-message-handler.js';
import { NotchBridge } from './events/notch.js';
import { buildProductionChecks } from './health.js';
import { getAdminDb } from './lib/admin-db.js';
import { startScheduler, stopScheduler } from './scheduler/index.js';
import { DurableRunStore } from './protocol/durable-run-store.js';
import { SupabaseReplayStore } from './protocol/replay.js';
import { SupabaseQuotaStore } from './security/quota-store.js';

const notch = new NotchBridge(config.notchWsUrl);
const fencingQuota = new SupabaseQuotaStore(getAdminDb('fencing'));
// The localhost bridge is development compatibility only. Production clients
// connect outbound through the authenticated fenced gateway below.
if (!config.isProduction) notch.connect();
const deviceStore = new SupabaseDeviceStore();
const devices = new DeviceService(deviceStore, {
  signingSecret: config.deviceGateway.signingSecret,
  issuer: config.publicBaseUrl,
  audience: config.deviceGateway.publicUrl,
  challengeTtlMs: config.deviceGateway.challengeTtlMs,
  ticketTtlMs: config.deviceGateway.ticketTtlMs,
  maxDevicesPerUser: config.deviceGateway.maxDevicesPerUser,
  supportedProtocolVersions: config.deviceGateway.supportedProtocolVersions,
});
const gateway = new DeviceGateway(devices, {
  path: config.deviceGateway.path,
  allowedOrigins: config.deviceGateway.allowedOrigins,
  supportedProtocolVersions: config.deviceGateway.supportedProtocolVersions,
  maxPayloadBytes: config.deviceGateway.maxPayloadBytes,
  maxMessagesPerWindow: config.deviceGateway.maxMessagesPerWindow,
  maxBytesPerWindow: config.deviceGateway.maxBytesPerWindow,
  rateWindowMs: config.deviceGateway.rateWindowMs,
  maxConnectionBytes: config.deviceGateway.maxConnectionBytes,
  maxBufferedBytes: config.deviceGateway.maxBufferedBytes,
  heartbeatIntervalMs: config.deviceGateway.heartbeatIntervalMs,
  heartbeatTimeoutMs: config.deviceGateway.heartbeatTimeoutMs,
  handshakeTimeoutMs: config.deviceGateway.handshakeTimeoutMs,
}, new SupabaseDeviceMessageHandler(
  getAdminDb('fencing'),
  new SupabaseReplayStore(getAdminDb('fencing'), fencingQuota),
  config.deviceGateway.replayPageSize,
));

// Build the DB adapter needed by readiness checks. Uses the fencing client
// (already available) for a lightweight ledger count probe.
const fencingDb = getAdminDb('fencing');
const readinessDbAdapter = {
  from: (table: string) => ({
    select: async (_col: string) => {
      const { error, count } = await fencingDb
        .from(table)
        .select('*', { count: 'exact', head: true });
      return { error, count: count ?? null };
    },
  }),
};

// Number of SQL migration files shipped in this build.
const EXPECTED_MIGRATION_COUNT = 11;

const readinessChecks = buildProductionChecks({
  db: readinessDbAdapter,
  gatewayReady: () => gateway.isReady(),
  providerConfigured: () => !!(process.env.ANTHROPIC_API_KEY || process.env.PROVIDER_KEY_SECRET),
  expectedMigrationCount: EXPECTED_MIGRATION_COUNT,
});

const app = createApp({ config, notch, devices, gateway, quota: fencingQuota, readinessChecks });
const server = createServer(app);
gateway.attach(server);

// ── Active-connection tracking for graceful drain ───────────────────────────

/** All open sockets including keep-alive HTTP connections. */
const activeSockets = new Set<Socket>();

server.on('connection', (socket: Socket) => {
  activeSockets.add(socket);
  socket.once('close', () => activeSockets.delete(socket));
});

/** True once SIGTERM/SIGINT has been received; new requests return 503. */
let isShuttingDown = false;

server.on('request', (_req: IncomingMessage, res: ServerResponse) => {
  if (isShuttingDown) {
    res.setHeader('Connection', 'close');
  }
});

// ── Server startup ──────────────────────────────────────────────────────────

// Bind to 0.0.0.0 on cloud platforms (Render, Railway, etc.) so the load
// balancer can reach the server. Fall back to loopback in local dev so the
// port is not externally exposed by default.
const host = process.env.HOST ?? (process.env.RENDER ? '0.0.0.0' : '127.0.0.1');
const recoveredRuns = await new DurableRunStore().recoverInterruptedStreams();
if (recoveredRuns > 0) {
  console.warn(`[perch-backend] Marked ${recoveredRuns} interrupted provider stream(s) recoverable`);
}
const replayRecovery = new SupabaseReplayStore(getAdminDb('fencing'), fencingQuota);
await replayRecovery.expireWaitingRuns(new Date().toISOString());
const waitingExpiryTimer = setInterval(() => {
  void replayRecovery.expireWaitingRuns(new Date().toISOString()).catch((error) => {
    console.error('[perch-backend] Waiting-device expiry failed closed', error);
  });
}, config.deviceGateway.waitingExpirySweepMs);
waitingExpiryTimer.unref();

server.listen(config.port, host, () => {
  console.log(`[perch-backend] http://localhost:${config.port}`);

  // Start scheduler after server is up
  startScheduler(notch);
});

// ── Graceful shutdown ───────────────────────────────────────────────────────

/**
 * Drain deadline: after SIGTERM, stop accepting new connections immediately,
 * give in-flight requests up to DRAIN_DEADLINE_MS to finish, then force-exit.
 * Any request that arrives after drain starts receives Connection: close so
 * the client can retry against a healthy replica.
 */
const DRAIN_DEADLINE_MS = parseInt(process.env.DRAIN_DEADLINE_MS ?? '10000', 10);

let shuttingDown = false;
async function shutdown(signal: string) {
  if (shuttingDown) return;
  shuttingDown = true;
  isShuttingDown = true;
  console.log(`\n[perch-backend] ${signal} received — draining (deadline ${DRAIN_DEADLINE_MS}ms)`);

  // Stop scheduler from picking up new tasks.
  stopScheduler();
  clearInterval(waitingExpiryTimer);
  notch.disconnect();

  // Stop accepting new connections. In-flight requests continue.
  server.close();

  // Force-close any idle keep-alive sockets so the drain completes sooner.
  // Sockets with active requests are left open until the response finishes.
  for (const socket of activeSockets) {
    const hasActiveRequest = !!(socket as unknown as Record<string, unknown>)['_httpMessage'];
    if (!hasActiveRequest) {
      socket.destroy();
      activeSockets.delete(socket);
    }
  }

  // Close the device gateway (fences all WebSocket sessions).
  await gateway.close();

  // Deadline: if sockets are still open after DRAIN_DEADLINE_MS, force exit.
  const drainTimer = setTimeout(() => {
    console.warn('[perch-backend] Drain deadline reached — forcing exit');
    for (const socket of activeSockets) socket.destroy();
    process.exit(0);
  }, DRAIN_DEADLINE_MS);
  // Keep the drain timer from preventing natural exit once all sockets close.
  drainTimer.unref();
}

process.on('SIGINT', () => void shutdown('SIGINT'));
process.on('SIGTERM', () => void shutdown('SIGTERM'));
