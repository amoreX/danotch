export type TaskStatus = 'pending' | 'running' | 'completed' | 'failed' | 'cancelled' | 'awaiting_approval';

export interface Task {
  id: string;
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

export interface TaskSummaryEvent {
  type: 'task_summary';
  tasks: Record<string, unknown>[];
}

export type NotchEvent = SubagentEvent | TaskSummaryEvent;
