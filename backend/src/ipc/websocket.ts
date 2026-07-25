import type { IncomingMessage, Server } from 'node:http';
import { WebSocketServer } from 'ws';
import type { Config } from '../config.js';
import { NotchBridge } from '../events/notch.js';
import { SessionManager } from '../security/session.js';
import type { ActionCoordinator } from '../actions/coordinator.js';

export function attachWebSocket(
  server: Server,
  sessions: SessionManager,
  bridge: NotchBridge,
  config: Config,
  actions?: ActionCoordinator,
): WebSocketServer {
  const wss = new WebSocketServer({
    noServer: true,
    maxPayload: config.wsMaxFrameBytes,
    perMessageDeflate: false,
    handleProtocols: (protocols) => protocols.has('perch.local.v1') ? 'perch.local.v1' : false,
  });

  server.on('upgrade', (request, socket, head) => {
    const isV1 = request.url === '/v1/events';
    const isLegacy = request.url === '/ipc/events';
    const protocols = String(request.headers['sec-websocket-protocol'] ?? '')
      .split(',').map((value) => value.trim());
    if (
      (!isV1 && !isLegacy)
      || (isV1 && !protocols.includes('perch.local.v1'))
      || !validRequest(request, sessions, config)
    ) {
      socket.write('HTTP/1.1 401 Unauthorized\r\nConnection: close\r\n\r\n');
      socket.destroy();
      return;
    }
    wss.handleUpgrade(request, socket, head, (client) => wss.emit('connection', client, request));
  });

  wss.on('connection', (client) => {
    bridge.add(client);
    let count = 0;
    let windowStart = Date.now();
    client.on('message', (raw) => {
      if (Date.now() - windowStart >= config.httpRateWindowMs) {
        count = 0;
        windowStart = Date.now();
      }
      count += 1;
      const bytes = Array.isArray(raw)
        ? raw.reduce((total, chunk) => total + chunk.byteLength, 0)
        : raw.byteLength;
      if (count > config.wsMaxMessagesPerWindow || bytes > config.wsMaxFrameBytes) {
        client.close(1008, 'Rate or frame limit exceeded');
        return;
      }
      if (!actions) return;
      try {
        const envelope = parseEnvelope(raw);
        let accepted = false;
        if (envelope.type === 'action_decision') {
          accepted = actions.handleActionDecision(envelope.payload);
        } else if (envelope.type === 'execution_result') {
          accepted = actions.handleExecutionResult(envelope.payload);
        } else if (envelope.type === 'connection_response') {
          accepted = actions.handleConnectionResponse(envelope.payload);
        } else {
          throw new Error('Unknown inbound IPC message');
        }
        if (!accepted) throw new Error('Stale or invalid inbound IPC message');
      } catch {
        client.close(1008, 'Invalid IPC message');
      }
    });
  });
  return wss;
}

function parseEnvelope(raw: import('ws').RawData): {
  v: number; type: string; id: string; payload: Record<string, unknown>;
} {
  const bytes = Array.isArray(raw) ? Buffer.concat(raw) : Buffer.from(raw as never);
  const value = JSON.parse(bytes.toString('utf8')) as Record<string, unknown>;
  if (
    value.v !== 1
    || typeof value.type !== 'string'
    || typeof value.id !== 'string'
    || !/^[A-Za-z0-9_-]{1,128}$/.test(value.id)
    || !value.payload
    || typeof value.payload !== 'object'
    || Array.isArray(value.payload)
    || Object.keys(value).some((key) => !['v', 'type', 'id', 'payload'].includes(key))
  ) throw new Error('Invalid IPC envelope');
  return value as {
    v: number; type: string; id: string; payload: Record<string, unknown>;
  };
}

function validRequest(request: IncomingMessage, sessions: SessionManager, config: Config): boolean {
  const host = request.headers.host;
  const expectedPort = request.socket.localPort;
  if (host !== `127.0.0.1:${expectedPort}`) return false;
  const origin = request.headers.origin;
  if (origin !== config.allowedOrigin) return false;
  const auth = request.headers.authorization;
  return typeof auth === 'string'
    && auth.startsWith('Bearer ')
    && sessions.authenticate(auth.slice(7));
}
