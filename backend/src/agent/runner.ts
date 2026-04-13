import { v4 as uuid } from 'uuid';
import type { NotchBridge } from '../events/notch.js';
import type { Task, ChatMessage } from '../types.js';
import type { CanonicalTool, CanonicalMessage, CanonicalContentBlock, CanonicalToolResultBlock } from '../providers/types.js';
import { getProviderForUser, getFallbackProvider } from '../providers/factory.js';
import { config } from '../config.js';
import { supabase } from '../lib/supabase.js';
import { scheduledTaskTools, executeScheduledTool } from '../tools/scheduled.js';
import { localTools, executeLocalTool } from '../tools/local.js';
import { loadComposioTools, executeComposioTool, loadToolsForApp, COMPOSIO_APPS } from '../composio/tools.js';
import { syncConnectionToDb } from '../composio/connection.js';

// Tool: request_app_connection — lets the agent ask the user to connect an app
const requestAppConnectionTool: CanonicalTool = {
  name: 'request_app_connection',
  description: 'Request the user to connect an app integration (Gmail, Google Calendar, Google Docs, Linear). Use this when you need tools from an app that is not yet connected. The user will see a permission prompt and can approve or deny. If approved, the app\'s tools become available immediately.',
  input_schema: {
    type: 'object',
    properties: {
      app_type: {
        type: 'string',
        enum: COMPOSIO_APPS.map(a => a.appType),
        description: 'The app to request connection for.',
      },
      reason: {
        type: 'string',
        description: 'Brief explanation of why you need this app (shown to the user). E.g. "To check your calendar events for today"',
      },
    },
    required: ['app_type', 'reason'],
  },
};

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
  threadId: string, sessionId: string, userMessage: string,
  assistantResponse: string, notch: NotchBridge, userId?: string
) {
  try {
    // Use user's provider for title generation, or fallback
    const provider = userId
      ? await getProviderForUser(userId)
      : getFallbackProvider();

    const result = await provider.complete({
      messages: [
        { role: 'user', content: userMessage },
        { role: 'assistant', content: assistantResponse.slice(0, 300) },
        { role: 'user', content: 'Title:' },
      ],
      systemPrompt: 'Generate a very short title (3-6 words max) for this conversation. Return ONLY the title, nothing else. No quotes.',
      maxTokens: 30,
    });

    const title = result.text.trim().slice(0, 80);

    if (title) {
      await supabase.from('threads').update({ title }).eq('id', threadId);
      console.log(`[runner] Thread title: "${title}"`);
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

// ── Chat runner (provider-agnostic with tool use) ──

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
    // Resolve the LLM provider: user's BYOK config → server fallback
    const provider = userId
      ? await getProviderForUser(userId)
      : getFallbackProvider();

    // Build conversation from in-memory history
    const canonicalMessages: CanonicalMessage[] = task.chatHistory
      .filter((m) => m.role === 'user' || m.role === 'agent')
      .map((m) => ({
        role: (m.role === 'user' ? 'user' : 'assistant') as 'user' | 'assistant',
        content: m.content,
      }));

    // All tools: local (bash, web) always, scheduled only if authed
    const tools: CanonicalTool[] = [
      ...localTools,
      ...(userId ? scheduledTaskTools : []),
    ];

    // Load Composio tools for all connected apps
    let composioToolNames = new Set<string>();
    let connectedAppNames: string[] = [];
    if (userId) {
      const composio = await loadComposioTools(userId);
      if (composio.tools.length > 0) {
        // Composio tools are compatible shape — cast to canonical
        tools.push(...(composio.tools as unknown as CanonicalTool[]));
        composioToolNames = composio.toolNames;
        connectedAppNames = composio.activeAppNames;
      }
      tools.push(requestAppConnectionTool);
    }

    // Build system prompt with connected app context
    let systemPrompt = config.api.systemPrompt;
    if (connectedAppNames.length > 0) {
      systemPrompt += `\n\nThe user has the following apps already connected: ${connectedAppNames.join(', ')}. Their tools are available to you — use them directly. Do NOT call request_app_connection for these apps.`;
    }

    // Tool-use loop: stream → handle tool calls → stream again
    let maxLoops = 5;
    while (maxLoops-- > 0) {
      const streamResult = await provider.stream({
        messages: canonicalMessages,
        tools: tools.length > 0 ? tools : undefined,
        systemPrompt,
        maxTokens: config.api.maxTokens,
        onText: (text) => {
          fullText += text;
          task.streamingText = fullText;
          notch.sendProgress(id, { type: 'token', text });
        },
      });

      // Check for tool use blocks
      const toolUseBlocks = streamResult.content.filter(
        (b): b is Extract<CanonicalContentBlock, { type: 'tool_use' }> => b.type === 'tool_use'
      );

      if (toolUseBlocks.length > 0) {
        // Flush any streamed text before tool calls as a separate chat message
        const preToolText = streamResult.content
          .filter((b): b is Extract<CanonicalContentBlock, { type: 'text' }> => b.type === 'text')
          .map((b) => b.text)
          .join('');
        if (preToolText.trim()) {
          task.chatHistory.push({ id: uuid(), role: 'agent', content: preToolText, timestamp: new Date() });
          notch.sendProgress(id, { type: 'text_flush', text: preToolText });
          fullText = '';
          task.streamingText = '';
        }

        // Add assistant message with all content blocks to conversation
        canonicalMessages.push({ role: 'assistant', content: streamResult.content });

        // Execute each tool and collect results
        const toolResults: CanonicalToolResultBlock[] = [];
        for (const toolBlock of toolUseBlocks) {
          const toolInput = toolBlock.input;
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
          const isComposioTool = composioToolNames.has(toolBlock.name);

          if (toolBlock.name === 'request_app_connection' && userId) {
            const appType = toolInput.app_type as string;
            const reason = toolInput.reason as string;
            const app = COMPOSIO_APPS.find(a => a.appType === appType);
            const displayName = app?.displayName ?? appType;
            const requestId = uuid();

            console.log(`[chat] Requesting ${displayName} connection from user...`);

            const approved = await notch.requestConnection(requestId, id, appType, displayName, reason);

            if (approved) {
              const newTools = await loadToolsForApp(userId, appType);
              if (newTools.tools.length > 0) {
                tools.push(...(newTools.tools as unknown as CanonicalTool[]));
                newTools.toolNames.forEach(n => composioToolNames.add(n));
              }
              result = `User approved. ${displayName} is now connected and its tools are available. Proceed with the user's request.`;
              console.log(`[chat] ${displayName} connected — ${newTools.tools.length} tools loaded`);
            } else {
              result = `User denied the ${displayName} connection. Do not request this app again in this conversation. Answer their question another way or explain what you would need.`;
              console.log(`[chat] ${displayName} connection denied by user`);
            }
          } else if (isComposioTool && userId) {
            result = await executeComposioTool(userId, {
              id: toolBlock.id,
              name: toolBlock.name,
              input: toolInput,
            });
          } else if (isScheduledTool && userId) {
            result = await executeScheduledTool(toolBlock.name, toolInput, userId);
          } else {
            result = await executeLocalTool(toolBlock.name, toolInput);
          }

          const resultSummary = result.slice(0, 300);
          console.log(`[chat] Tool result: ${resultSummary.slice(0, 150)}`);

          notch.sendProgress(id, {
            type: 'tool_result',
            tool_name: toolBlock.name,
            tool_input: inputSummary,
            tool_output: resultSummary,
          });

          task.chatHistory.push({
            id: uuid(), role: 'tool',
            content: resultSummary,
            toolName: toolBlock.name,
            timestamp: new Date(),
          });

          const MAX_TOOL_RESULT_CHARS = 8000;
          const truncatedResult = result.length > MAX_TOOL_RESULT_CHARS
            ? result.slice(0, MAX_TOOL_RESULT_CHARS) + '\n\n[Truncated — result was ' + result.length.toLocaleString() + ' chars]'
            : result;

          toolResults.push({
            type: 'tool_result',
            tool_use_id: toolBlock.id,
            content: truncatedResult,
          });
        }

        // Add tool results to conversation and loop for next response
        canonicalMessages.push({ role: 'user', content: toolResults });
        task.currentToolName = undefined;
        continue;
      }

      // No tool use — we're done
      const responseText = streamResult.content
        .filter((b): b is Extract<CanonicalContentBlock, { type: 'text' }> => b.type === 'text')
        .map((b) => b.text)
        .join('');

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
            input_tokens: streamResult.usage.inputTokens,
            output_tokens: streamResult.usage.outputTokens,
            tools_used: toolsUsed,
            model: provider.modelId,
            provider: provider.providerName,
            status: 'completed',
          });
          await updateThreadTimestamp(threadId);
          if (!options?.threadId) {
            await generateThreadTitle(threadId, id, message, finalResponseText, notch, userId);
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
