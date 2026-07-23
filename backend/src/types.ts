export type TaskStatus = 'running' | 'completed' | 'failed';
export type DurableRunStatus =
  | 'queued'
  | 'provider_streaming'
  | 'checkpointed'
  | 'waiting_for_device'
  | 'cancellation_requested'
  | 'completed'
  | 'failed'
  | 'failed_recoverable'
  | 'cancelled'
  | 'expired';

export interface DurableRun {
  id: string;
  readonly ownerId: string;
  readonly deviceId: string | null;
  protocolVersion: 1;
  status: DurableRunStatus;
  revision: number;
  input: Record<string, unknown>;
  checkpoint: Record<string, unknown> | null;
}

export interface Task {
  id: string;
  readonly ownerId: string;
  task: string;
  description?: string;
  status: TaskStatus;
  toolCallsCount: number;
  currentToolName?: string;
  streamingText: string;
  result?: string;
  error?: string;
  createdAt: Date;
  completedAt?: Date;
  chatHistory: ChatMessage[];
}

export interface ChatMessage {
  id: string;
  role: 'user' | 'agent' | 'tool';
  content: string;
  toolName?: string;
  timestamp: Date;
}

// WebSocket events sent to the notch app
export interface SubagentEvent {
  type: 'subagent_event';
  session_id: string;
  event_type: 'status' | 'progress' | 'done';
  data: Record<string, unknown>;
}

export interface ConnectionRequestEvent {
  type: 'connection_request';
  request_id: string;
  session_id: string;
  app_type: string;
  display_name: string;
  reason: string;
}

// A draft external action awaiting the user's explicit approval. The app renders
// an approve/reject card and calls /api/actions/:id/{approve,reject}.
export interface PendingActionEvent {
  type: 'pending_action';
  action_id: string;
  session_id: string;
  action_type: string;
  summary: string;
}

export type NotchEvent = SubagentEvent | ConnectionRequestEvent | PendingActionEvent;
