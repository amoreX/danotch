import WebSocket from 'ws';
import type { NotchEvent } from '../types.js';

// WebSocket client that connects to the notch app's server on :7778
export class NotchBridge {
  private ws: WebSocket | null = null;
  private reconnectTimer: ReturnType<typeof setTimeout> | null = null;
  private url: string;

  constructor(url = 'ws://localhost:7778/ws') {
    this.url = url;
  }

  connect() {
    console.log(`[NotchBridge] Connecting to ${this.url}...`);

    this.ws = new WebSocket(this.url);

    this.ws.on('open', () => {
      console.log('[NotchBridge] Connected to notch app');
      if (this.reconnectTimer) {
        clearTimeout(this.reconnectTimer);
        this.reconnectTimer = null;
      }
    });

    this.ws.on('message', (data) => {
      // Messages from the notch app (e.g. user approval/rejection)
      try {
        const msg = JSON.parse(data.toString());
        console.log('[NotchBridge] Received from notch:', msg.type);
        this.handleNotchMessage(msg);
      } catch {
        // ignore parse errors
      }
    });

    this.ws.on('close', () => {
      console.log('[NotchBridge] Disconnected from notch app');
      this.ws = null;
      this.scheduleReconnect();
    });

    this.ws.on('error', (err) => {
      console.log('[NotchBridge] Connection error:', err.message);
      this.ws = null;
      this.scheduleReconnect();
    });
  }

  private scheduleReconnect() {
    if (this.reconnectTimer) return;
    this.reconnectTimer = setTimeout(() => {
      this.reconnectTimer = null;
      this.connect();
    }, 3000);
  }

  private handleNotchMessage(_msg: Record<string, unknown>) {
    // TODO: handle approval/rejection from notch UI
  }

  send(event: NotchEvent) {
    if (this.ws?.readyState === WebSocket.OPEN) {
      this.ws.send(JSON.stringify(event));
    }
  }

  // Convenience: send a status update for a task
  sendStatus(sessionId: string, data: Record<string, unknown>) {
    this.send({
      type: 'subagent_event',
      session_id: sessionId,
      event_type: 'status',
      data,
    });
  }

  // Convenience: send a progress update
  sendProgress(sessionId: string, data: Record<string, unknown>) {
    this.send({
      type: 'subagent_event',
      session_id: sessionId,
      event_type: 'progress',
      data,
    });
  }

  // Convenience: send done
  sendDone(sessionId: string, data: Record<string, unknown>) {
    this.send({
      type: 'subagent_event',
      session_id: sessionId,
      event_type: 'done',
      data,
    });
  }

  get connected(): boolean {
    return this.ws?.readyState === WebSocket.OPEN;
  }

  disconnect() {
    if (this.reconnectTimer) {
      clearTimeout(this.reconnectTimer);
      this.reconnectTimer = null;
    }
    this.ws?.close();
    this.ws = null;
  }
}
