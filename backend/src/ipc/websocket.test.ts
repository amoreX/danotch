import assert from 'node:assert/strict';
import { randomBytes } from 'node:crypto';
import { createServer } from 'node:http';
import type { AddressInfo } from 'node:net';
import { test } from 'node:test';
import WebSocket from 'ws';
import { loadConfig } from '../config.ts';
import { NotchBridge } from '../events/notch.ts';
import { SessionManager } from '../security/session.ts';
import { attachWebSocket } from './websocket.ts';
import type { ActionCoordinator } from '../actions/coordinator.ts';

test('v1 event socket requires and negotiates perch.local.v1', async () => {
  const secret = randomBytes(32);
  const encoded = secret.toString('base64');
  const sessions = new SessionManager(Buffer.from(secret), 60_000);
  const token = sessions.exchange(encoded)!.token;
  const server = createServer();
  const bridge = new NotchBridge();
  const wss = attachWebSocket(server, sessions, bridge, loadConfig({}));
  await new Promise<void>((resolve) => server.listen(0, '127.0.0.1', resolve));
  const port = (server.address() as AddressInfo).port;
  const socket = new WebSocket(`ws://127.0.0.1:${port}/v1/events`, 'perch.local.v1', {
    headers: { Authorization: `Bearer ${token}`, Origin: 'perch://app' },
  });
  try {
    await new Promise<void>((resolve, reject) => {
      socket.once('open', resolve);
      socket.once('error', reject);
    });
    assert.equal(socket.protocol, 'perch.local.v1');
  } finally {
    socket.close();
    bridge.close();
    sessions.close();
    await new Promise<void>((resolve) => wss.close(() => resolve()));
    await new Promise<void>((resolve) => server.close(() => resolve()));
  }
});

test('authenticated inbound IPC enforces versioned schema and routes allowed responses', async () => {
  const secret = randomBytes(32);
  const encoded = secret.toString('base64');
  const sessions = new SessionManager(secret, 60_000);
  const token = sessions.exchange(encoded)!.token;
  const server = createServer();
  const bridge = new NotchBridge();
  const received: string[] = [];
  const actions = {
    handleActionDecision() { received.push('action_decision'); return true; },
    handleExecutionResult() { received.push('execution_result'); return true; },
    handleConnectionResponse() { received.push('connection_response'); return true; },
  } as unknown as ActionCoordinator;
  const wss = attachWebSocket(server, sessions, bridge, loadConfig({}), actions);
  await new Promise<void>((resolve) => server.listen(0, '127.0.0.1', resolve));
  const port = (server.address() as AddressInfo).port;
  const socket = new WebSocket(`ws://127.0.0.1:${port}/v1/events`, 'perch.local.v1', {
    headers: { Authorization: `Bearer ${token}`, Origin: 'perch://app' },
  });
  try {
    await new Promise<void>((resolve, reject) => {
      socket.once('open', resolve);
      socket.once('error', reject);
    });
    socket.send(JSON.stringify({
      v: 1, type: 'connection_response', id: 'message-1',
      payload: { request_id: 'request-1', approved: true },
    }));
    await new Promise((resolve) => setTimeout(resolve, 10));
    assert.deepEqual(received, ['connection_response']);
    const closed = new Promise<number>((resolve) => socket.once('close', resolve));
    socket.send(JSON.stringify({
      v: 2, type: 'action_decision', id: 'message-2', payload: {},
    }));
    assert.equal(await closed, 1008);
  } finally {
    bridge.close();
    sessions.close();
    await new Promise<void>((resolve) => wss.close(() => resolve()));
    await new Promise<void>((resolve) => server.close(() => resolve()));
  }
});

test('authenticated inbound IPC closes clients that exceed message rate', async () => {
  const secret = randomBytes(32);
  const encoded = secret.toString('base64');
  const sessions = new SessionManager(secret, 60_000);
  const token = sessions.exchange(encoded)!.token;
  const server = createServer();
  const bridge = new NotchBridge();
  const actions = {
    handleActionDecision() { return true; },
    handleExecutionResult() { return true; },
    handleConnectionResponse() { return true; },
  } as unknown as ActionCoordinator;
  const config = loadConfig({ WS_MAX_MESSAGES_PER_WINDOW: '10' });
  const wss = attachWebSocket(server, sessions, bridge, config, actions);
  await new Promise<void>((resolve) => server.listen(0, '127.0.0.1', resolve));
  const port = (server.address() as AddressInfo).port;
  const socket = new WebSocket(`ws://127.0.0.1:${port}/v1/events`, 'perch.local.v1', {
    headers: { Authorization: `Bearer ${token}`, Origin: 'perch://app' },
  });
  try {
    await new Promise<void>((resolve, reject) => {
      socket.once('open', resolve);
      socket.once('error', reject);
    });
    const closed = new Promise<number>((resolve) => socket.once('close', resolve));
    for (let index = 0; index < 11; index += 1) {
      socket.send(JSON.stringify({
        v: 1,
        type: 'connection_response',
        id: `message-${index}`,
        payload: { request_id: `request-${index}`, approved: false },
      }));
    }
    assert.equal(await closed, 1008);
  } finally {
    bridge.close();
    sessions.close();
    await new Promise<void>((resolve) => wss.close(() => resolve()));
    await new Promise<void>((resolve) => server.close(() => resolve()));
  }
});
