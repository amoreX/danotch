import type { WebSocket } from 'ws';
import type { NotchEvent } from '../types.js';

export class NotchBridge {
  private readonly clients = new Set<WebSocket>();

  add(client: WebSocket): void {
    this.clients.add(client);
    client.once('close', () => this.clients.delete(client));
  }

  send(event: NotchEvent | { type: string; [key: string]: unknown }): void {
    const encoded = JSON.stringify(event);
    for (const client of this.clients) {
      if (client.readyState === client.OPEN) client.send(encoded);
    }
  }

  sendStatus(sessionId: string, data: Record<string, unknown>): void {
    this.send({
      type: 'subagent_event',
      session_id: sessionId,
      event_type: 'status',
      data,
    });
  }

  sendProgress(sessionId: string, data: Record<string, unknown>): void {
    this.send({
      type: 'subagent_event',
      session_id: sessionId,
      event_type: 'progress',
      data,
    });
  }

  sendDone(sessionId: string, data: Record<string, unknown>): void {
    this.send({
      type: 'subagent_event',
      session_id: sessionId,
      event_type: 'done',
      data,
    });
  }

  sendPendingAction(actionId: string, sessionId: string, actionType: string, summary: string): void {
    this.send({
      type: 'pending_action',
      action_id: actionId,
      session_id: sessionId,
      action_type: actionType,
      summary,
    });
  }

  get connected(): boolean {
    return this.clients.size > 0;
  }

  close(): void {
    for (const client of this.clients) client.close(1001, 'Daemon shutting down');
    this.clients.clear();
  }
}
