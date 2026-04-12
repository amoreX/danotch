import WebSocket from 'ws';
import type { NotchEvent } from '../types.js';

// WebSocket client that connects to the notch app's server on :7778
export class NotchBridge {
  private ws: WebSocket | null = null;
  private reconnectTimer: ReturnType<typeof setTimeout> | null = null;
  private url: string;

  // Pending connection requests waiting for user approval/denial
  private pendingRequests = new Map<string, {
    resolve: (approved: boolean) => void;
    timer: ReturnType<typeof setTimeout>;
  }>();

  constructor(url: string) {
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
      try {
        const msg = JSON.parse(data.toString());
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

  private handleNotchMessage(msg: Record<string, unknown>) {
    if (msg.type === 'connection_response') {
      const requestId = msg.request_id as string;
      const approved = msg.approved as boolean;
      console.log(`[NotchBridge] Connection response: ${requestId} → ${approved ? 'approved' : 'denied'}`);

      const pending = this.pendingRequests.get(requestId);
      if (pending) {
        clearTimeout(pending.timer);
        this.pendingRequests.delete(requestId);
        pending.resolve(approved);
      }
    }
  }

  /**
   * Send a connection request to the notch app and wait for user response.
   * Returns true if user approved, false if denied or timed out.
   */
  requestConnection(
    requestId: string,
    sessionId: string,
    appType: string,
    displayName: string,
    reason: string,
  ): Promise<boolean> {
    return new Promise((resolve) => {
      // Timeout after 120s (OAuth can take a while)
      const timer = setTimeout(() => {
        if (this.pendingRequests.has(requestId)) {
          console.log(`[NotchBridge] Connection request timed out: ${requestId}`);
          this.pendingRequests.delete(requestId);
          resolve(false);
        }
      }, 120_000);

      this.pendingRequests.set(requestId, { resolve, timer });

      this.send({
        type: 'connection_request',
        request_id: requestId,
        session_id: sessionId,
        app_type: appType,
        display_name: displayName,
        reason: reason,
      });
    });
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
    // Reject all pending requests
    for (const [id, pending] of this.pendingRequests) {
      clearTimeout(pending.timer);
      pending.resolve(false);
    }
    this.pendingRequests.clear();
    this.ws?.close();
    this.ws = null;
  }
}
