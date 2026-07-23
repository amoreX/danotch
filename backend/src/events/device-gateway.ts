import type { IncomingMessage, Server } from 'node:http';
import type { Duplex } from 'node:stream';
import { WebSocket, WebSocketServer, type RawData } from 'ws';
import type { ConsumedDeviceTicket, DeviceService } from '../devices/device-service.js';

export interface DeviceGatewayMessage {
  v: number;
  type:
    | 'ack'
    | 'action_decision'
    | 'consume_grant'
    | 'action_result'
    | 'cancel_run'
    | 'logout'
    | 'pong';
  id: string;
  payload: Record<string, unknown>;
}

export interface DeviceGatewayOutboundMessage {
  v: number;
  type:
    | 'reconnect_contract'
    | 'event'
    | 'snapshot'
    | 'execution_grant'
    | 'grant_consumed'
    | 'result_ack';
  id: string;
  payload: Record<string, unknown>;
}

export interface DeviceGatewayOptions {
  path: string;
  allowedOrigins: readonly string[];
  supportedProtocolVersions: readonly number[];
  maxPayloadBytes: number;
  maxMessagesPerWindow: number;
  maxBytesPerWindow: number;
  rateWindowMs: number;
  maxConnectionBytes: number;
  maxBufferedBytes: number;
  heartbeatIntervalMs: number;
  heartbeatTimeoutMs: number;
  handshakeTimeoutMs: number;
}

export interface DeviceGatewayHandler {
  onConnect?(
    identity: ConsumedDeviceTicket,
  ): Promise<readonly DeviceGatewayOutboundMessage[] | void>;
  onMessage(
    identity: ConsumedDeviceTicket,
    message: DeviceGatewayMessage,
  ): Promise<readonly DeviceGatewayOutboundMessage[] | void>;
  onDisconnect?(identity: ConsumedDeviceTicket): Promise<void>;
}

interface SocketState {
  identity: ConsumedDeviceTicket;
  windowStartedAt: number;
  windowMessages: number;
  windowBytes: number;
  connectionBytes: number;
  pendingBytes: number;
  lastPongAt: number;
  processing: Promise<void>;
}

const MESSAGE_TYPES = new Set<DeviceGatewayMessage['type']>([
  'ack',
  'action_decision',
  'consume_grant',
  'action_result',
  'cancel_run',
  'logout',
  'pong',
]);
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

function rejectUpgrade(socket: Duplex, status: number, message: string): void {
  if (!socket.destroyed) {
    socket.write(
      `HTTP/1.1 ${status} ${message}\r\n`
      + 'Connection: close\r\n'
      + 'Content-Type: text/plain\r\n'
      + 'Cache-Control: no-store\r\n'
      + `Content-Length: ${Buffer.byteLength(message)}\r\n\r\n`
      + message,
    );
  }
  socket.destroy();
}

function parseProtocols(header: string | string[] | undefined): string[] {
  const value = Array.isArray(header) ? header.join(',') : header;
  return value?.split(',').map((item) => item.trim()).filter(Boolean) ?? [];
}

function ticketFromRequest(request: IncomingMessage): string | null {
  const authorization = request.headers.authorization;
  const authTicket = typeof authorization === 'string' && authorization.startsWith('Bearer ')
    ? authorization.slice(7)
    : null;
  const ticketProtocol = parseProtocols(request.headers['sec-websocket-protocol'])
    .find((protocol) => protocol.startsWith('perch-ticket.'));
  let protocolTicket: string | null = null;
  if (ticketProtocol) {
    try {
      protocolTicket = Buffer.from(ticketProtocol.slice('perch-ticket.'.length), 'base64url').toString();
    } catch {
      return null;
    }
  }
  if (authTicket && protocolTicket && authTicket !== protocolTicket) return null;
  return authTicket ?? protocolTicket;
}

function parseMessage(data: RawData, isBinary: boolean): DeviceGatewayMessage | null {
  if (isBinary) return null;
  let value: unknown;
  try {
    value = JSON.parse(data.toString());
  } catch {
    return null;
  }
  if (!value || typeof value !== 'object' || Array.isArray(value)) return null;
  const record = value as Record<string, unknown>;
  if (
    Object.keys(record).some((key) => !['v', 'type', 'id', 'payload'].includes(key))
    || Object.keys(record).length !== 4
    || !Number.isSafeInteger(record.v)
    || typeof record.type !== 'string'
    || !MESSAGE_TYPES.has(record.type as DeviceGatewayMessage['type'])
    || typeof record.id !== 'string'
    || !UUID.test(record.id)
    || !record.payload
    || typeof record.payload !== 'object'
    || Array.isArray(record.payload)
  ) {
    return null;
  }
  return record as unknown as DeviceGatewayMessage;
}

export class DeviceGateway {
  private readonly wss: WebSocketServer;
  private readonly state = new WeakMap<WebSocket, SocketState>();
  private readonly currentSockets = new Map<string, WebSocket>();
  private server: Server | null = null;
  private heartbeat: ReturnType<typeof setInterval> | null = null;
  private readonly upgradeHandler = (
    request: IncomingMessage,
    socket: Duplex,
    head: Buffer,
  ) => {
    void this.upgrade(request, socket, head);
  };

  constructor(
    private readonly devices: DeviceService,
    private readonly options: DeviceGatewayOptions,
    private readonly handler: DeviceGatewayHandler,
  ) {
    this.wss = new WebSocketServer({
      noServer: true,
      maxPayload: options.maxPayloadBytes,
      perMessageDeflate: false,
      clientTracking: true,
      handleProtocols: (protocols) => {
        for (const version of this.options.supportedProtocolVersions) {
          const protocol = `perch.v${version}`;
          if (protocols.has(protocol)) return protocol;
        }
        return false;
      },
    });
    this.wss.on('error', () => {
      console.error('[device-gateway] Server error');
    });
  }

  attach(server: Server): void {
    if (this.server) throw new Error('Device gateway is already attached');
    this.server = server;
    server.on('upgrade', this.upgradeHandler);
    this.heartbeat = setInterval(() => this.checkHeartbeats(), this.options.heartbeatIntervalMs);
    this.heartbeat.unref();
  }

  /** True when the gateway is attached to an HTTP server and accepting upgrades. */
  isReady(): boolean {
    return this.server !== null;
  }

  private async upgrade(request: IncomingMessage, socket: Duplex, head: Buffer): Promise<void> {
    const timedSocket = socket as Duplex & {
      setTimeout(milliseconds: number, callback?: () => void): void;
    };
    timedSocket.setTimeout(this.options.handshakeTimeoutMs, () => socket.destroy());
    try {
      const parsed = new URL(request.url ?? '/', 'http://gateway.invalid');
      if (parsed.pathname !== this.options.path) {
        rejectUpgrade(socket, 404, 'WebSocket endpoint not found');
        return;
      }
      if (parsed.search) {
        rejectUpgrade(socket, 400, 'Gateway credentials and query parameters are forbidden');
        return;
      }
      const origin = request.headers.origin;
      if (typeof origin !== 'string' || !this.options.allowedOrigins.includes(origin)) {
        rejectUpgrade(socket, 403, 'Origin rejected');
        return;
      }
      const offeredProtocols = parseProtocols(request.headers['sec-websocket-protocol']);
      const offeredVersion = this.options.supportedProtocolVersions
        .find((version) => offeredProtocols.includes(`perch.v${version}`));
      if (offeredVersion === undefined) {
        rejectUpgrade(socket, 426, 'Supported WebSocket protocol required');
        return;
      }
      const ticket = ticketFromRequest(request);
      if (!ticket) {
        rejectUpgrade(socket, 401, 'Gateway ticket required');
        return;
      }
      const identity = await this.devices.consumeTicket(ticket);
      if (identity.protocolVersion !== offeredVersion) {
        rejectUpgrade(socket, 426, 'Ticket protocol does not match negotiated protocol');
        return;
      }
      if (socket.destroyed) return;
      timedSocket.setTimeout(0);
      this.wss.handleUpgrade(request, socket, head, (ws) => {
        this.connected(ws, request, identity);
      });
    } catch {
      rejectUpgrade(socket, 401, 'Gateway ticket rejected');
    }
  }

  private connected(
    socket: WebSocket,
    _request: IncomingMessage,
    identity: ConsumedDeviceTicket,
  ): void {
    const key = this.socketKey(identity.userId, identity.deviceId);
    const previous = this.currentSockets.get(key);
    if (previous && previous !== socket) previous.close(4002, 'Superseded by newer fence');
    this.currentSockets.set(key, socket);
    const currentTime = Date.now();
    this.state.set(socket, {
      identity,
      windowStartedAt: currentTime,
      windowMessages: 0,
      windowBytes: 0,
      connectionBytes: 0,
      pendingBytes: 0,
      lastPongAt: currentTime,
      processing: Promise.resolve(),
    });

    socket.on('pong', () => {
      const state = this.state.get(socket);
      if (state) state.lastPongAt = Date.now();
    });
    socket.on('message', (data, isBinary) => {
      const state = this.state.get(socket);
      if (!state) return;
      state.processing = state.processing
        .then(() => this.message(socket, data, isBinary))
        .catch(() => {
          if (socket.readyState === WebSocket.OPEN) {
            socket.close(1011, 'Message processing failed');
          }
        });
    });
    socket.on('error', () => {
      // Close handles cleanup. Malformed frames affect only this connection.
    });
    socket.on('close', () => {
      if (this.currentSockets.get(key) === socket) this.currentSockets.delete(key);
      void this.handler.onDisconnect?.(identity).catch(() => {});
    });
    const state = this.state.get(socket)!;
    state.processing = this.initialize(socket, state);
  }

  private async initialize(socket: WebSocket, state: SocketState): Promise<void> {
    try {
      const messages = await this.handler.onConnect?.(state.identity);
      await this.sendMessages(socket, messages);
    } catch {
      socket.close(1013, 'Recovery storage unavailable');
    }
  }

  private async sendMessages(
    socket: WebSocket,
    messages: readonly DeviceGatewayOutboundMessage[] | void,
  ): Promise<void> {
    for (const message of messages ?? []) {
      if (socket.readyState !== WebSocket.OPEN) return;
      const encoded = JSON.stringify(message);
      if (
        Buffer.byteLength(encoded) > this.options.maxPayloadBytes
        || socket.bufferedAmount + Buffer.byteLength(encoded) > this.options.maxBufferedBytes
      ) {
        socket.close(4007, 'Backpressure limit exceeded');
        return;
      }
      await new Promise<void>((resolve, reject) => {
        socket.send(encoded, (error) => error ? reject(error) : resolve());
      });
    }
  }

  private async message(socket: WebSocket, data: RawData, isBinary: boolean): Promise<void> {
    const state = this.state.get(socket);
    if (!state || socket.readyState !== WebSocket.OPEN) return;
    const bytes = data instanceof ArrayBuffer
      ? data.byteLength
      : Array.isArray(data)
        ? data.reduce((sum, chunk) => sum + chunk.length, 0)
        : data.length;
    const currentTime = Date.now();
    if (currentTime - state.windowStartedAt >= this.options.rateWindowMs) {
      state.windowStartedAt = currentTime;
      state.windowMessages = 0;
      state.windowBytes = 0;
    }
    state.windowMessages += 1;
    state.windowBytes += bytes;
    state.connectionBytes += bytes;
    state.pendingBytes += bytes;
    if (
      state.windowMessages > this.options.maxMessagesPerWindow
      || state.windowBytes > this.options.maxBytesPerWindow
      || state.connectionBytes > this.options.maxConnectionBytes
    ) {
      socket.close(4005, 'Message or byte rate exceeded');
      state.pendingBytes -= bytes;
      return;
    }
    if (
      socket.bufferedAmount > this.options.maxBufferedBytes
      || state.pendingBytes > this.options.maxBufferedBytes
    ) {
      socket.close(4007, 'Backpressure limit exceeded');
      state.pendingBytes -= bytes;
      return;
    }
    try {
      const message = parseMessage(data, isBinary);
      if (!message) {
        socket.close(4004, 'Malformed message');
        return;
      }
      if (message.v !== state.identity.protocolVersion) {
        socket.close(4003, 'Unsupported protocol version');
        return;
      }
      if (!await this.devices.store.assertCurrentFence(
        state.identity.userId,
        state.identity.deviceId,
        state.identity.fence,
      )) {
        socket.close(4002, 'Stale or revoked device fence');
        return;
      }
      if (message.type === 'pong') {
        state.lastPongAt = currentTime;
        return;
      }
      if (message.type === 'logout') {
        await this.devices.fenceConnectionLogout(
          state.identity.userId,
          state.identity.deviceId,
          state.identity.fence,
        );
        this.closeUser(state.identity.userId, 4008, 'Logout fenced device sessions');
        return;
      }
      const messages = await this.handler.onMessage(state.identity, message);
      await this.sendMessages(socket, messages);
    } catch (error) {
      if (
        error
        && typeof error === 'object'
        && 'code' in error
        && error.code === 'invalid_protocol_message'
      ) {
        socket.close(4004, 'Malformed message payload');
      } else {
        socket.close(1011, 'Message processing failed');
      }
    } finally {
      state.pendingBytes -= bytes;
    }
  }

  private checkHeartbeats(): void {
    const currentTime = Date.now();
    for (const socket of this.wss.clients) {
      const state = this.state.get(socket);
      if (!state) continue;
      if (currentTime - state.lastPongAt > this.options.heartbeatTimeoutMs) {
        socket.close(4006, 'Heartbeat timeout');
      } else if (socket.bufferedAmount > this.options.maxBufferedBytes) {
        socket.close(4007, 'Backpressure limit exceeded');
      } else if (socket.readyState === WebSocket.OPEN) {
        socket.ping();
      }
    }
  }

  closeDevice(userId: string, deviceId: string, code = 4008, reason = 'Device revoked'): void {
    this.currentSockets.get(this.socketKey(userId, deviceId))?.close(code, reason);
  }

  closeUser(userId: string, code = 4008, reason = 'Account sessions fenced'): void {
    for (const socket of this.wss.clients) {
      const state = this.state.get(socket);
      if (state?.identity.userId === userId) socket.close(code, reason);
    }
  }

  async close(): Promise<void> {
    if (this.heartbeat) clearInterval(this.heartbeat);
    this.heartbeat = null;
    if (this.server) this.server.off('upgrade', this.upgradeHandler);
    this.server = null;
    for (const socket of this.wss.clients) socket.terminate();
    await new Promise<void>((resolve) => this.wss.close(() => resolve()));
  }

  private socketKey(userId: string, deviceId: string): string {
    return `${userId}:${deviceId}`;
  }
}
