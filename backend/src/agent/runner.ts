import { query } from '@anthropic-ai/claude-agent-sdk';
import Anthropic from '@anthropic-ai/sdk';
import { v4 as uuid } from 'uuid';
import type { NotchBridge } from '../events/notch.js';
import type { Task, ChatMessage } from '../types.js';
import { config } from '../config.js';
import { supabase } from '../lib/supabase.js';

const anthropic = new Anthropic();

// In-memory task store (for real-time streaming state)
const tasks = new Map<string, Task>();

export function getTask(id: string): Task | undefined {
  return tasks.get(id);
}

export function getAllTasks(): Task[] {
  return Array.from(tasks.values()).sort(
    (a, b) => b.createdAt.getTime() - a.createdAt.getTime()
  );
}

// ── DB helpers (fire-and-forget — never block streaming) ──

function dbSave(fn: () => Promise<void>) {
  fn().catch((err) => console.error('[runner:db]', err));
}

async function ensureThread(userId: string, threadId?: string, title?: string): Promise<string> {
  if (threadId) {
    const { data } = await supabase
      .from('threads')
      .select('id')
      .eq('id', threadId)
      .eq('user_id', userId)
      .single();
    if (data) return data.id;
  }

  const id = threadId ?? uuid();
  const { data, error } = await supabase
    .from('threads')
    .insert({ id, user_id: userId, title: title?.slice(0, 80) })
    .select('id')
    .single();

  if (error) {
    console.error('[runner] Failed to create thread:', error.message);
    return id;
  }
  return data.id;
}

async function saveMessage(
  threadId: string,
  userId: string,
  role: 'user' | 'assistant',
  content: string,
  metadata?: Record<string, unknown>
) {
  const { error } = await supabase.from('messages').insert({
    thread_id: threadId,
    user_id: userId,
    role,
    content,
    metadata: metadata ?? {},
  });
  if (error) {
    console.error(`[runner] Failed to save ${role} message:`, error.message);
  }
}

async function updateThreadTimestamp(threadId: string) {
  await supabase
    .from('threads')
    .update({ updated_at: new Date().toISOString() })
    .eq('id', threadId);
}

// ── Agent runner (Claude Agent SDK with tools) ──

export async function runAgent(
  message: string,
  notch: NotchBridge,
  options?: { sessionId?: string; cwd?: string; userId?: string; threadId?: string }
): Promise<Task & { threadId: string }> {
  const id = options?.sessionId ?? uuid();
  const userId = options?.userId;

  let threadId = id;
  if (userId) {
    threadId = await ensureThread(userId, options?.threadId, message);
    // Save user message (awaited — we want it in DB before streaming starts)
    await saveMessage(threadId, userId, 'user', message);
  }

  const task = createOrUpdateTask(id, message);
  notch.sendStatus(id, {
    task: task.task,
    description: task.description,
    status: 'running',
    tool_calls_count: task.toolCallsCount,
  });

  let lastText = '';
  const toolsUsed: { name: string; timestamp: string }[] = [];

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

    for await (const event of agentQuery) {
      switch (event.type) {
        case 'assistant': {
          const msg = event.message;
          for (const block of msg.content) {
            if (block.type === 'text') {
              lastText = block.text;
              notch.sendProgress(id, { type: 'token', text: block.text });
            }
            if (block.type === 'tool_use') {
              task.toolCallsCount++;
              task.currentToolName = block.name;
              toolsUsed.push({ name: block.name, timestamp: new Date().toISOString() });
              notch.sendProgress(id, { type: 'tool_start', tool_name: block.name });
              task.chatHistory.push({
                id: uuid(), role: 'tool', content: `Using ${block.name}`,
                toolName: block.name, timestamp: new Date(),
              });
            }
          }
          break;
        }
        case 'result': {
          if (event.subtype === 'success') lastText = event.result;
          break;
        }
        case 'stream_event': {
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

    // Success
    task.chatHistory.push({ id: uuid(), role: 'agent', content: lastText, timestamp: new Date() });
    task.status = 'completed';
    task.result = lastText;
    task.completedAt = new Date();
    task.currentToolName = undefined;
    task.streamingText = '';

    // Fire-and-forget DB save
    if (userId) {
      dbSave(async () => {
        await saveMessage(threadId, userId, 'assistant', lastText, {
          tools_used: toolsUsed,
          model: config.agent.model,
          status: 'completed',
        });
        await updateThreadTimestamp(threadId);
      });
    }

    notch.sendDone(id, { status: 'completed', result: lastText });
    return { ...task, threadId };
  } catch (err) {
    const errorMsg = err instanceof Error ? err.message : 'Unknown error';
    task.status = 'failed';
    task.error = errorMsg;
    task.completedAt = new Date();

    // Save error + whatever partial content and tools we accumulated
    if (userId) {
      const partialText = lastText || task.streamingText || '';
      dbSave(async () => {
        await saveMessage(threadId, userId, 'assistant', partialText || '[No response — request failed]', {
          tools_used: toolsUsed,
          model: config.agent.model,
          status: 'failed',
          error: errorMsg,
          partial: partialText.length > 0,
        });
        await updateThreadTimestamp(threadId);
      });
    }

    notch.sendDone(id, { status: 'failed', error: errorMsg });
    return { ...task, threadId };
  }
}

// ── Chat runner (Anthropic API, no tools) ──

export async function runChat(
  message: string,
  notch: NotchBridge,
  options?: { sessionId?: string; userId?: string; threadId?: string }
): Promise<Task & { threadId: string }> {
  const id = options?.sessionId ?? uuid();
  const userId = options?.userId;

  let threadId = id;
  if (userId) {
    threadId = await ensureThread(userId, options?.threadId, message);
    await saveMessage(threadId, userId, 'user', message);
  }

  const task = createOrUpdateTask(id, message);

  notch.sendStatus(id, {
    task: task.task,
    description: task.description,
    status: 'running',
    tool_calls_count: 0,
  });

  let fullText = '';

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

    stream.on('text', (text) => {
      fullText += text;
      task.streamingText = fullText;
      notch.sendProgress(id, { type: 'token', text });
    });

    const finalMessage = await stream.finalMessage();
    const inputTokens = finalMessage.usage?.input_tokens ?? 0;
    const outputTokens = finalMessage.usage?.output_tokens ?? 0;

    const responseText = finalMessage.content
      .filter((b): b is Anthropic.TextBlock => b.type === 'text')
      .map((b) => b.text)
      .join('');

    task.chatHistory.push({ id: uuid(), role: 'agent', content: responseText, timestamp: new Date() });
    task.status = 'completed';
    task.result = responseText;
    task.completedAt = new Date();
    task.streamingText = '';

    // Fire-and-forget DB save
    if (userId) {
      dbSave(async () => {
        await saveMessage(threadId, userId, 'assistant', responseText, {
          input_tokens: inputTokens,
          output_tokens: outputTokens,
          model: config.api.model,
          status: 'completed',
        });
        await updateThreadTimestamp(threadId);
      });
    }

    notch.sendDone(id, { status: 'completed', result: responseText });
    return { ...task, threadId };
  } catch (err) {
    const errorMsg = err instanceof Error ? err.message : 'Unknown error';
    task.status = 'failed';
    task.error = errorMsg;
    task.completedAt = new Date();

    // Save error + whatever partial streaming text we got
    if (userId) {
      const partialText = fullText || task.streamingText || '';
      dbSave(async () => {
        await saveMessage(threadId, userId, 'assistant', partialText || '[No response — request failed]', {
          model: config.api.model,
          status: 'failed',
          error: errorMsg,
          partial: partialText.length > 0,
        });
        await updateThreadTimestamp(threadId);
      });
    }

    notch.sendDone(id, { status: 'failed', error: errorMsg });
    return { ...task, threadId };
  }
}

// ── Thread queries ──

export async function getThreads(userId: string) {
  const { data, error } = await supabase
    .from('threads')
    .select('id, title, created_at, updated_at')
    .eq('user_id', userId)
    .order('updated_at', { ascending: false })
    .limit(50);
  if (error) {
    console.error('[runner] Failed to get threads:', error.message);
    return [];
  }
  return data;
}

export async function getThreadMessages(userId: string, threadId: string) {
  const { data, error } = await supabase
    .from('messages')
    .select('id, role, content, metadata, created_at')
    .eq('thread_id', threadId)
    .eq('user_id', userId)
    .order('created_at', { ascending: true });
  if (error) {
    console.error('[runner] Failed to get messages:', error.message);
    return [];
  }
  return data;
}

export async function deleteThread(userId: string, threadId: string) {
  const { error } = await supabase
    .from('threads')
    .delete()
    .eq('id', threadId)
    .eq('user_id', userId);
  if (error) {
    console.error('[runner] Failed to delete thread:', error.message);
    return false;
  }
  return true;
}

// ── Helpers ──

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
  task.chatHistory.push({ id: uuid(), role: 'user', content: message, timestamp: new Date() });
  return task;
}
