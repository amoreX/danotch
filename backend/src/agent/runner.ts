import { query } from '@anthropic-ai/claude-agent-sdk';
import Anthropic from '@anthropic-ai/sdk';
import { v4 as uuid } from 'uuid';
import type { NotchBridge } from '../events/notch.js';
import type { Task, ChatMessage } from '../types.js';
import { config } from '../config.js';

const anthropic = new Anthropic();

// In-memory task store
const tasks = new Map<string, Task>();

export function getTask(id: string): Task | undefined {
  return tasks.get(id);
}

export function getAllTasks(): Task[] {
  return Array.from(tasks.values()).sort(
    (a, b) => b.createdAt.getTime() - a.createdAt.getTime()
  );
}

// Run a task using Claude Agent SDK (has access to tools: Bash, Read, Edit, etc.)
export async function runAgent(
  message: string,
  notch: NotchBridge,
  options?: { sessionId?: string; cwd?: string }
): Promise<Task> {
  const id = options?.sessionId ?? uuid();

  const task = createOrUpdateTask(id, message);
  notch.sendStatus(id, {
    task: task.task,
    description: task.description,
    status: 'running',
    tool_calls_count: task.toolCallsCount,
  });

  try {
    const agentQuery = query({
      prompt: message,
      options: {
        model: config.agent.model,
        maxTurns: config.agent.maxTurns,
        systemPrompt: config.agent.systemPrompt,
        permissionMode: config.agent.permissionMode,
        cwd: options?.cwd || process.cwd(),
      },
    });

    let lastText = '';

    for await (const event of agentQuery) {
      switch (event.type) {
        case 'assistant': {
          // Full assistant message with content blocks
          const msg = event.message;
          for (const block of msg.content) {
            if (block.type === 'text') {
              lastText = block.text;
              notch.sendProgress(id, { type: 'token', text: block.text });
            }
            if (block.type === 'tool_use') {
              task.toolCallsCount++;
              task.currentToolName = block.name;
              notch.sendProgress(id, {
                type: 'tool_start',
                tool_name: block.name,
              });

              task.chatHistory.push({
                id: uuid(),
                role: 'tool',
                content: `Using ${block.name}`,
                toolName: block.name,
                timestamp: new Date(),
              });
            }
          }
          break;
        }

        case 'result': {
          if (event.subtype === 'success') {
            lastText = event.result;
          }
          break;
        }

        case 'stream_event': {
          // Streaming token events
          const streamEvent = event.event;
          if (streamEvent.type === 'content_block_delta') {
            const delta = streamEvent.delta;
            if ('text' in delta && delta.text) {
              task.streamingText += delta.text;
              notch.sendProgress(id, { type: 'token', text: delta.text });
            }
          }
          break;
        }

        default:
          break;
      }
    }

    // Done
    task.chatHistory.push({
      id: uuid(),
      role: 'agent',
      content: lastText,
      timestamp: new Date(),
    });

    task.status = 'completed';
    task.result = lastText;
    task.completedAt = new Date();
    task.currentToolName = undefined;
    task.streamingText = '';

    notch.sendDone(id, { status: 'completed', result: lastText });
    return task;
  } catch (err) {
    return handleError(task, id, err, notch);
  }
}

// Run a simple chat using the Anthropic API (no tools, just conversation)
export async function runChat(
  message: string,
  notch: NotchBridge,
  sessionId?: string
): Promise<Task> {
  const id = sessionId ?? uuid();
  const task = createOrUpdateTask(id, message);

  notch.sendStatus(id, {
    task: task.task,
    description: task.description,
    status: 'running',
    tool_calls_count: 0,
  });

  try {
    const messages: Anthropic.MessageParam[] = task.chatHistory
      .filter((m) => m.role === 'user' || m.role === 'agent')
      .map((m) => ({
        role: m.role === 'user' ? ('user' as const) : ('assistant' as const),
        content: m.content,
      }));

    const stream = await anthropic.messages.stream({
      model: config.api.model,
      max_tokens: config.api.maxTokens,
      system: config.api.systemPrompt,
      messages,
    });

    let fullText = '';
    stream.on('text', (text) => {
      fullText += text;
      task.streamingText = fullText;
      notch.sendProgress(id, { type: 'token', text });
    });

    const finalMessage = await stream.finalMessage();
    const responseText = finalMessage.content
      .filter((b): b is Anthropic.TextBlock => b.type === 'text')
      .map((b) => b.text)
      .join('');

    task.chatHistory.push({
      id: uuid(),
      role: 'agent',
      content: responseText,
      timestamp: new Date(),
    });

    task.status = 'completed';
    task.result = responseText;
    task.completedAt = new Date();
    task.streamingText = '';

    notch.sendDone(id, { status: 'completed', result: responseText });
    return task;
  } catch (err) {
    return handleError(task, id, err, notch);
  }
}

// Helpers

function createOrUpdateTask(id: string, message: string): Task {
  let task = tasks.get(id);
  if (!task) {
    task = {
      id,
      task: message,
      description: message.slice(0, 60),
      status: 'running',
      toolCallsCount: 0,
      streamingText: '',
      createdAt: new Date(),
      chatHistory: [],
    };
    tasks.set(id, task);
  } else {
    task.status = 'running';
    task.streamingText = '';
  }

  task.chatHistory.push({
    id: uuid(),
    role: 'user',
    content: message,
    timestamp: new Date(),
  });

  return task;
}

function handleError(task: Task, id: string, err: unknown, notch: NotchBridge): Task {
  const errorMsg = err instanceof Error ? err.message : 'Unknown error';
  task.status = 'failed';
  task.error = errorMsg;
  task.completedAt = new Date();
  notch.sendDone(id, { status: 'failed', error: errorMsg });
  return task;
}
