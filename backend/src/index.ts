import { randomUUID } from 'node:crypto';
import { createServer } from 'node:http';
import { release } from 'node:os';
import type { AddressInfo, Socket } from 'node:net';
import { createApp } from './app.js';
import { config } from './config.js';
import { openDatabase, verifyDatabase } from './db/database.js';
import { Repositories } from './db/repositories.js';
import { NotchBridge } from './events/notch.js';
import { readInstallationSecret } from './ipc/bootstrap.js';
import { removeDiscoveryFile, writeDiscoveryFile } from './ipc/discovery.js';
import { KeychainBroker } from './ipc/keychain-broker.js';
import { attachWebSocket } from './ipc/websocket.js';
import { LocalScheduler } from './scheduler/index.js';
import { SessionManager } from './security/session.js';
import { ActionCoordinator } from './actions/coordinator.js';
import { LocalComposioService } from './composio/service.js';

assertSupportedRuntime();
const instanceId = randomUUID();
const database = openDatabase(config.databasePath);
verifyDatabase(database);
const repositories = new Repositories(database);
const installationSecret = await readInstallationSecret();
const sessions = new SessionManager(installationSecret, config.sessionTtlMs);
const broker = new KeychainBroker();
const events = new NotchBridge();
const actions = new ActionCoordinator(repositories, events);
const composio = new LocalComposioService(repositories, broker);
let port = 0;
const app = createApp({
  config, repositories, broker, sessions, events, getPort: () => port, instanceId,
  actions, composio,
});
const server = createServer(app);
const webSocketServer = attachWebSocket(server, sessions, events, config, actions);
const scheduler = new LocalScheduler({ repositories, broker, events, config, composio });
const sockets = new Set<Socket>();
server.on('connection', (socket) => {
  sockets.add(socket);
  socket.once('close', () => sockets.delete(socket));
});

await new Promise<void>((resolve, reject) => {
  server.once('error', reject);
  server.listen(0, config.host, () => {
    port = (server.address() as AddressInfo).port;
    writeDiscoveryFile(config.discoveryPath, { port, pid: process.pid, protocolVersion: 1, instanceId });
    scheduler.start();
    console.error(`[perch-daemon] listening on 127.0.0.1:${port}`);
    resolve();
  });
});

let stopping = false;
async function shutdown(signal: string): Promise<void> {
  if (stopping) return;
  stopping = true;
  console.error(`[perch-daemon] ${signal} received; draining`);
  scheduler.stop();
  sessions.close();
  broker.close();
  events.close();
  webSocketServer.close();
  server.close();
  removeDiscoveryFile(config.discoveryPath, instanceId);
  const deadline = setTimeout(() => {
    for (const socket of sockets) socket.destroy();
  }, config.drainDeadlineMs);
  deadline.unref();
  database.close();
}
process.on('SIGINT', () => void shutdown('SIGINT'));
process.on('SIGTERM', () => void shutdown('SIGTERM'));

export function assertSupportedRuntime(
  platform = process.platform,
  arch = process.arch,
  kernelRelease = release(),
): void {
  const darwinMajor = Number.parseInt(kernelRelease.split('.')[0] ?? '', 10);
  if (platform !== 'darwin' || arch !== 'arm64' || !Number.isFinite(darwinMajor) || darwinMajor < 25) {
    throw new Error('Perch local daemon requires macOS 26 or newer on Apple Silicon');
  }
}
