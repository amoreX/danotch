import Anthropic from '@anthropic-ai/sdk';
import { v4 as uuid } from 'uuid';
import type { NotchBridge } from '../events/notch.js';
import type { Task, ChatMessage } from '../types.js';
import { config } from '../config.js';
import { supabase } from '../lib/supabase.js';
import { scheduledTaskTools, executeScheduledTool } from '../tools/scheduled.js';
import { localTools, executeLocalTool } from '../tools/local.js';

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

async function generateThreadTitle(
  threadId: string, sessionId: string, userMessage: string, assistantResponse: string, notch: NotchBridge
) {
  try {
    const resp = await anthropic.messages.create({
      model: config.api.model,
      max_tokens: 30,
      system: 'Generate a very short title (3-6 words max) for this conversation. Return ONLY the title, nothing else. No quotes.',
      messages: [
        { role: 'user', content: userMessage },
        { role: 'assistant', content: assistantResponse.slice(0, 300) },
        { role: 'user', content: 'Title:' },
      ],
    });
    const title = resp.content
      .filter((b): b is Anthropic.TextBlock => b.type === 'text')
      .map((b) => b.text)
      .join('')
      .trim()
      .slice(0, 80);

    if (title) {
      await supabase.from('threads').update({ title }).eq('id', threadId);
      console.log(`[runner] Thread title: "${title}"`);
      // Push title update to app
      notch.send({
        type: 'subagent_event',
        session_id: sessionId,
        event_type: 'status',
        data: { title, description: title },
      });
    }
  } catch (e) {
    // Non-critical, ignore
  }
}

// ── Chat runner (Anthropic API with tool use) ──

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
  const toolsUsed: { name: string; input?: string; timestamp: string }[] = [];

  try {
    // Build conversation from in-memory history
    const apiMessages: Anthropic.MessageParam[] = task.chatHistory
      .filter((m) => m.role === 'user' || m.role === 'agent')
      .map((m) => ({
        role: m.role === 'user' ? ('user' as const) : ('assistant' as const),
        content: m.content,
      }));

    // Include scheduled task tools if user is authenticated
    // All tools: local (bash, web) always, scheduled only if authed
    const tools: Anthropic.Tool[] = [
      ...localTools,
      ...(userId ? scheduledTaskTools : []),
    ];

    // Tool-use loop: stream → handle tool calls → stream again
    let maxLoops = 5;
    while (maxLoops-- > 0) {
      const stream = await anthropic.messages.stream({
        model: config.api.model,
        max_tokens: config.api.maxTokens,
        system: config.api.systemPrompt,
        messages: apiMessages,
        ...(tools.length > 0 ? { tools } : {}),
      });

      stream.on('text', (text) => {
        fullText += text;
        task.streamingText = fullText;
        notch.sendProgress(id, { type: 'token', text });
      });

      const finalMessage = await stream.finalMessage();

      // Check for tool use
      const toolUseBlocks = finalMessage.content.filter(
        (b): b is Anthropic.ToolUseBlock => b.type === 'tool_use'
      );

      if (toolUseBlocks.length > 0) {
        // Add assistant message with tool calls to conversation
        apiMessages.push({ role: 'assistant', content: finalMessage.content });

        // Execute each tool and collect results
        const toolResults: Anthropic.ToolResultBlockParam[] = [];
        for (const toolBlock of toolUseBlocks) {
          const toolInput = toolBlock.input as Record<string, unknown>;
          const inputSummary = summarizeToolInput(toolBlock.name, toolInput);

          task.toolCallsCount++;
          task.currentToolName = toolBlock.name;
          toolsUsed.push({ name: toolBlock.name, input: inputSummary, timestamp: new Date().toISOString() });

          notch.sendProgress(id, {
            type: 'tool_start',
            tool_name: toolBlock.name,
            tool_input: inputSummary,
          });
          console.log(`[chat] Tool call: ${toolBlock.name} → ${inputSummary}`);

          // Route to correct handler
          let result: string;
          const isScheduledTool = scheduledTaskTools.some(t => t.name === toolBlock.name);
          if (isScheduledTool && userId) {
            result = await executeScheduledTool(toolBlock.name, toolInput, userId);
          } else {
            result = await executeLocalTool(toolBlock.name, toolInput);
          }

          const resultSummary = result.slice(0, 300);
          console.log(`[chat] Tool result: ${resultSummary.slice(0, 150)}`);

          // Send tool result to notch app
          notch.sendProgress(id, {
            type: 'tool_result',
            tool_name: toolBlock.name,
            tool_input: inputSummary,
            tool_output: resultSummary,
          });

          // Add to chat history with detail
          task.chatHistory.push({
            id: uuid(), role: 'tool',
            content: resultSummary,
            toolName: toolBlock.name,
            timestamp: new Date(),
          });

          toolResults.push({
            type: 'tool_result',
            tool_use_id: toolBlock.id,
            content: result,
          });
        }

        // Add tool results to conversation and loop for Claude's response
        apiMessages.push({ role: 'user', content: toolResults });
        task.currentToolName = undefined;
        continue;
      }

      // No tool use — we're done
      const responseText = finalMessage.content
        .filter((b): b is Anthropic.TextBlock => b.type === 'text')
        .map((b) => b.text)
        .join('');

      const inputTokens = finalMessage.usage?.input_tokens ?? 0;
      const outputTokens = finalMessage.usage?.output_tokens ?? 0;

      const finalResponseText = responseText || fullText;

      task.chatHistory.push({ id: uuid(), role: 'agent', content: finalResponseText, timestamp: new Date() });
      task.status = 'completed';
      task.result = finalResponseText;
      task.completedAt = new Date();
      task.streamingText = '';
      task.currentToolName = undefined;

      if (userId) {
        dbSave(async () => {
          await saveMessage(threadId, userId, 'assistant', finalResponseText, {
            input_tokens: inputTokens,
            output_tokens: outputTokens,
            tools_used: toolsUsed,
            model: config.api.model,
            status: 'completed',
          });
          await updateThreadTimestamp(threadId);
          // Generate title for new threads (first message only)
          if (!options?.threadId) {
            await generateThreadTitle(threadId, id, message, finalResponseText, notch);
          }
        });
      }

      notch.sendDone(id, { status: 'completed', result: finalResponseText });
      return { ...task, threadId };
    }

    // Exhausted loop — shouldn't happen but handle gracefully
    const fallback = fullText || 'Completed (max tool calls reached)';
    task.status = 'completed';
    task.result = fallback;
    task.completedAt = new Date();
    notch.sendDone(id, { status: 'completed', result: fallback });
    return { ...task, threadId };
  } catch (err) {
    const errorMsg = err instanceof Error ? err.message : 'Unknown error';
    task.status = 'failed';
    task.error = errorMsg;
    task.completedAt = new Date();

    if (userId) {
      const partialText = fullText || task.streamingText || '';
      dbSave(async () => {
        await saveMessage(threadId, userId, 'assistant', partialText || '[No response — request failed]', {
          tools_used: toolsUsed,
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

function summarizeToolInput(toolName: string, input: Record<string, unknown>): string {
  switch (toolName) {
    case 'bash_execute': return (input.command as string)?.slice(0, 80) ?? '';
    case 'web_search': return (input.query as string) ?? '';
    case 'web_fetch': return (input.url as string) ?? '';
    case 'create_scheduled_task': return (input.name as string) ?? '';
    case 'list_scheduled_tasks': return '';
    case 'update_scheduled_task': return (input.id as string)?.slice(0, 8) ?? '';
    case 'delete_scheduled_task': return (input.id as string)?.slice(0, 8) ?? '';
    default: return JSON.stringify(input).slice(0, 80);
  }
}

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
