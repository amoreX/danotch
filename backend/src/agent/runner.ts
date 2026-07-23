import { v4 as uuid } from 'uuid';
import type { NotchBridge } from '../events/notch.js';
import type { Task, ChatMessage } from '../types.js';
import type { CanonicalTool, CanonicalMessage, CanonicalContentBlock, CanonicalToolResultBlock } from '../providers/types.js';
import { config } from '../config.js';
import { userDb as supabase } from '../lib/user-db.js';
import { resolveProviderForUser } from '../billing/entitlements.js';
import { scheduledTaskTools, executeScheduledTool } from '../tools/scheduled.js';
import { hostedTools, executeHostedTool } from '../tools/local.js';
import { loadComposioTools, executeComposioTool, loadToolsForApp, COMPOSIO_APPS } from '../composio/tools.js';
import { syncConnectionToDb } from '../composio/connection.js';
import { summarizeAction } from '../actions/allowlist.js';
import { ACTION_REGISTRY_VERSION, classifyAction } from '../actions/registry.js';
import { createPendingAction } from '../actions/pending.js';
import { InMemoryTaskStore } from './task-store.js';
import {
  DurableRunStore,
  getOwnerRun,
  listOwnerRuns,
  type DurableRunRecord,
} from '../protocol/durable-run-store.js';
import { getAdminDb } from '../lib/admin-db.js';
import { SupabaseQuotaStore, requestQuotaSubject } from '../security/quota-store.js';

const providerSpendQuota = new SupabaseQuotaStore(getAdminDb('runner'));

// Tool: request_app_connection — lets the agent ask the user to connect an app
const requestAppConnectionTool: CanonicalTool = {
  name: 'request_app_connection',
  description: 'Request the user to connect an app integration (Gmail, Google Calendar, Google Docs, GitHub). Use this when you need tools from an app that is not yet connected. The user will see a permission prompt and can approve or deny. If approved, the app\'s tools become available immediately.',
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

// Compatibility-only delivery cache for the legacy notch stream. Durable runs
// are authoritative; no authorization or outcome is derived from this cache.
const tasks = new InMemoryTaskStore();

export async function getTask(ownerId: string, id: string): Promise<Task | undefined> {
  const run = await getOwnerRun(ownerId, id);
  return run ? taskFromDurableRun(run) : undefined;
}

export async function getAllTasks(ownerId: string): Promise<Task[]> {
  return (await listOwnerRuns(ownerId)).map(taskFromDurableRun);
}

// ── DB helpers (fire-and-forget — never block streaming) ──

function dbSave(fn: () => Promise<void>) {
  fn().catch((err) => console.error('[runner:db]', err));
}

async function ensureThread(userId: string, threadId?: string, title?: string): Promise<string> {
  if (threadId) {
    const { data } = await supabase
      .from('danotch_threads')
      .select('id')
      .eq('id', threadId)
      .eq('user_id', userId)
      .single();
    if (data) return data.id;
  }

  const id = threadId ?? uuid();
  const { data, error } = await supabase
    .from('danotch_threads')
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
  const { error } = await supabase.from('danotch_messages').insert({
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
    .from('danotch_threads')
    .update({ updated_at: new Date().toISOString() })
    .eq('id', threadId);
}

async function generateThreadTitle(
  threadId: string, sessionId: string, userMessage: string,
  assistantResponse: string, notch: NotchBridge, userId?: string, fallbackModelId?: string
) {
  try {
    // Use user's provider for title generation, or fallback
    if (!userId) return;
    const provider = (await resolveProviderForUser(
      userId,
      fallbackModelId,
      supabase,
      { trialDb: getAdminDb('runner') },
    )).provider;

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
  options?: {
    sessionId?: string;
    userId?: string;
    conversationId?: string;
    modelId?: string;
    deviceId?: string;
    idempotencyKey?: string;
    history?: { role: 'user' | 'assistant'; content: string }[];
    durableStore?: DurableRunStore;
  }
): Promise<Task & { threadId: string }> {
  const userId = options?.userId;
  if (!userId) {
    throw new Error('Authenticated owner is required');
  }
  const requestedSessionId = options?.sessionId;
  let id = uuid();
  let threadId = options?.conversationId ?? id;
  await providerSpendQuota.consume({
    capability: 'provider',
    subject: requestQuotaSubject({ userId, deviceId: options?.deviceId }),
    idempotencyKey: options?.idempotencyKey ?? requestedSessionId ?? id,
  });

  // Resolve the LLM provider BEFORE creating a task or emitting status. An
  // entitlement failure (trial expired, provider key required, operational)
  // must propagate to the route as a deterministic error, not be swallowed
  // into a "failed" task. Authenticated users can use the server key only
  // during trial; after that they need an active BYOK provider.
  const provider = (await resolveProviderForUser(
    userId,
    options?.modelId,
    supabase,
    { trialDb: getAdminDb('runner') },
  )).provider;

  const durableStore = options?.durableStore ?? new DurableRunStore();
  let durableRun = await durableStore.create({
    runId: id,
    ownerId: userId,
    deviceId: options?.deviceId ?? null,
    idempotencyKey: options?.idempotencyKey ?? requestedSessionId ?? id,
    input: {
      kind: 'chat',
      message,
      conversationId: options?.conversationId ?? null,
      modelId: options?.modelId ?? null,
    },
  });
  if (durableRun.id !== id || durableRun.state !== 'queued') {
    const existing = taskFromDurableRun(durableRun);
    return { ...existing, threadId: options?.conversationId ?? durableRun.id };
  }
  id = durableRun.id;
  threadId = options?.conversationId ?? id;

  const task = createOrUpdateTask(userId, id, message);

  durableRun = await durableStore.transition(durableRun, {
    transitionId: uuid(),
    targetState: 'provider_streaming',
    eventType: 'provider_stream_started',
  });

  notch.sendStatus(id, {
    task: task.task,
    description: task.description,
    status: 'running',
    tool_calls_count: 0,
  });

  let fullText = '';
  const toolsUsed: { name: string; input?: string; timestamp: string }[] = [];

  try {

    // Conversation history is owned by the app and sent with each request.
    const canonicalMessages: CanonicalMessage[] = [
      ...(options?.history ?? []),
      { role: 'user' as const, content: message },
    ]
      .map((m) => ({
        role: m.role,
        content: m.content,
      }));

    const tools: CanonicalTool[] = [
      ...hostedTools,
      ...scheduledTaskTools.filter(
        (tool) => config.containment.costlyIntegrationsEnabled || tool.name !== 'create_scheduled_task',
      ),
    ];

    // Load Composio tools for all connected apps
    let composioToolNames = new Set<string>();
    let connectedAppNames: string[] = [];
    {
      const composio = await loadComposioTools(userId);
      if (composio.tools.length > 0) {
        // Composio tools are compatible shape — cast to canonical
        tools.push(...(composio.tools as unknown as CanonicalTool[]));
        composioToolNames = composio.toolNames;
        connectedAppNames = composio.activeAppNames;
      }
      if (config.containment.costlyIntegrationsEnabled) {
        tools.push(requestAppConnectionTool);
      }
    }

    // Build system prompt with connected app context
    let systemPrompt = config.api.systemPrompt;
    if (connectedAppNames.length > 0) {
      systemPrompt += `\n\nThe user has the following apps already connected: ${connectedAppNames.join(', ')}. Their tools are available to you — use them directly. Do NOT call request_app_connection for these apps.`;
    }

    // Tool-use loop: stream → handle tool calls → stream again
    let maxLoops = 5;
    while (maxLoops-- > 0) {
      let streamResult;
      try {
        streamResult = await provider.stream({
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
      } catch (streamError) {
        console.error('[runner] Provider stream interrupted:', streamError);
        const message = 'Provider stream interrupted';
        durableRun = await durableStore.transition(durableRun, {
          transitionId: uuid(),
          targetState: 'failed_recoverable',
          eventType: 'provider_stream_interrupted',
          payload: {
            code: 'provider_stream_interrupted',
            detail: message.slice(0, 500),
            retryCreatesNewRun: true,
          },
        });
        throw new RecoverableProviderStreamError(message);
      }

      // Check for tool use blocks
      const toolUseBlocks = streamResult.content.filter(
        (b): b is Extract<CanonicalContentBlock, { type: 'tool_use' }> => b.type === 'tool_use'
      );

      if (toolUseBlocks.length > 0) {
        durableRun = await durableStore.transition(durableRun, {
          transitionId: uuid(),
          targetState: 'checkpointed',
          eventType: 'provider_checkpointed',
          checkpoint: {
            boundary: 'provider_response_complete',
            completedToolLoops: 5 - maxLoops,
            toolUseIds: toolUseBlocks.map((block) => block.id),
          },
        });

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
          const isScheduledTool = tools.some(
            (tool) => tool.name === toolBlock.name,
          ) && scheduledTaskTools.some((tool) => tool.name === toolBlock.name);
          const isComposioTool = composioToolNames.has(toolBlock.name);

          if (
            toolBlock.name === 'request_app_connection'
            && config.containment.costlyIntegrationsEnabled
          ) {
            const appType = toolInput.app_type as string;
            const reason = toolInput.reason as string;
            const app = COMPOSIO_APPS.find(a => a.appType === appType);
            const displayName = app?.displayName ?? appType;
            const requestId = uuid();

            console.log(`[chat] Requesting ${displayName} connection from user...`);

            const approved = await notch.requestConnection(requestId, id, appType, displayName, reason);

            if (approved) {
              // Persist the connection to the DB so it survives into later
              // chats (tool loading reads only active DB rows), then load tools
              // for this in-flight conversation.
              const toolkitSlug = app?.toolkitSlug ?? appType;
              await syncConnectionToDb(userId, appType, toolkitSlug);
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
          } else if (isComposioTool) {
            const policy = classifyAction(toolBlock.name, {
              registryVersion: ACTION_REGISTRY_VERSION,
              metadataValidated: composioToolNames.has(toolBlock.name),
            });
            if (policy.kind === 'deny') {
              result = `External action denied: ${policy.reason}`;
            } else if (policy.kind === 'approval') {
            // Mutating external action: do NOT execute. Create a durable pending
            // action holding the immutable payload and ask the user to approve.
            const summary = summarizeAction(toolBlock.name, toolInput);
            const appType = toolBlock.name.startsWith('GMAIL_') ? 'gmail'
              : toolBlock.name.startsWith('GOOGLECALENDAR_') ? 'googlecalendar'
                : toolBlock.name.startsWith('GOOGLEDOCS_') ? 'googledocs'
                  : toolBlock.name.startsWith('GITHUB_') ? 'github' : '';
            const { data: connectedAccount } = appType
              ? await supabase.from('danotch_connected_apps')
                .select('composio_conn_id')
                .eq('user_id', userId)
                .eq('app_type', appType)
                .eq('active', true)
                .single()
              : { data: null };
            const created = await createPendingAction({
              userId,
              sessionId: id,
              actionType: toolBlock.name,
              summary,
              payload: toolInput,
              accountId: connectedAccount?.composio_conn_id ?? '',
              deviceId: options?.deviceId ?? '',
            });
              if ('error' in created) {
                result = `Could not prepare this action for approval: ${created.error}`;
              } else {
                notch.sendPendingAction(created.id, id, toolBlock.name, summary);
                result = `This action needs the user's approval before it runs. A draft (${summary}) is now awaiting their decision in the app. Do not retry it; wait for the user to approve or reject.`;
              }
            } else {
              result = await executeComposioTool(userId, {
                id: toolBlock.id,
                name: toolBlock.name,
                input: toolInput,
              });
            }
          } else if (isScheduledTool) {
            result = await executeScheduledTool(toolBlock.name, toolInput, userId);
          } else if (hostedTools.some((tool) => tool.name === toolBlock.name)) {
            result = await executeHostedTool(toolBlock.name, toolInput);
          } else {
            result = `Tool denied: ${toolBlock.name} is not registered for hosted execution`;
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
        durableRun = await durableStore.transition(durableRun, {
          transitionId: uuid(),
          targetState: 'provider_streaming',
          eventType: 'provider_stream_started',
          payload: { resumedFromCheckpoint: durableRun.revision },
        });
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

      durableRun = await durableStore.transition(durableRun, {
        transitionId: uuid(),
        targetState: 'completed',
        eventType: 'run_completed',
        payload: { result: finalResponseText, toolsUsed },
      });

      if ((options?.history?.length ?? 0) === 0) {
        dbSave(async () => {
          await generateThreadTitle(threadId, id, message, finalResponseText, notch, userId, options?.modelId);
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
    durableRun = await durableStore.transition(durableRun, {
      transitionId: uuid(),
      targetState: 'completed',
      eventType: 'run_completed',
      payload: { result: fallback, code: 'max_tool_loops_reached', toolsUsed },
    });
    notch.sendDone(id, { status: 'completed', result: fallback });
    return { ...task, threadId };
  } catch (err) {
    const errorMsg = err instanceof RecoverableProviderStreamError
      ? err.message
      : 'The request could not be completed.';
    console.error('[runner] Run failed:', err);
    task.status = 'failed';
    task.error = errorMsg;
    task.completedAt = new Date();

    if (!(err instanceof RecoverableProviderStreamError) && !isTerminalRun(durableRun)) {
      try {
        durableRun = await durableStore.transition(durableRun, {
          transitionId: uuid(),
          targetState: 'failed',
          eventType: 'run_failed',
          payload: { code: 'run_failed', detail: errorMsg.slice(0, 500) },
        });
      } catch (persistError) {
        console.error('[runner] Failed to persist terminal run state:', persistError);
        throw persistError;
      }
    }

    notch.sendDone(id, {
      status: 'failed',
      error: err instanceof RecoverableProviderStreamError
        ? `Provider stream interrupted. Retry creates a new run: ${errorMsg}`
        : errorMsg,
    });
    return { ...task, threadId };
  }
}

// ── Thread queries ──

export async function getThreads(userId: string) {
  const { data, error } = await supabase
    .from('danotch_threads')
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
    .from('danotch_messages')
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
    .from('danotch_threads')
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
    case 'web_search': return (input.query as string) ?? '';
    case 'web_fetch': return (input.url as string) ?? '';
    case 'create_scheduled_task': return (input.name as string) ?? '';
    case 'list_scheduled_tasks': return '';
    case 'update_scheduled_task': return (input.id as string)?.slice(0, 8) ?? '';
    case 'delete_scheduled_task': return (input.id as string)?.slice(0, 8) ?? '';
    default: return JSON.stringify(input).slice(0, 80);
  }
}

function createOrUpdateTask(ownerId: string, id: string, message: string): Task {
  const task = tasks.createOrUpdate(ownerId, id, message);
  task.chatHistory.push({ id: uuid(), role: 'user', content: message, timestamp: new Date() });
  return task;
}

class RecoverableProviderStreamError extends Error {}

function isTerminalRun(run: DurableRunRecord): boolean {
  return ['completed', 'failed', 'failed_recoverable', 'cancelled', 'expired'].includes(run.state);
}

function taskFromDurableRun(run: DurableRunRecord): Task {
  const message = typeof run.input.message === 'string' ? run.input.message : 'Run';
  const status: Task['status'] = run.state === 'completed'
    ? 'completed'
    : isTerminalRun(run)
      ? 'failed'
      : 'running';
  const result = typeof run.terminalResult?.result === 'string'
    ? run.terminalResult.result
    : undefined;
  return {
    id: run.id,
    ownerId: run.userId,
    task: message,
    description: message.slice(0, 60),
    status,
    toolCallsCount: 0,
    streamingText: '',
    result,
    error: run.state === 'failed_recoverable'
      ? 'Provider stream interrupted; retry creates a new run'
      : typeof run.terminalResult?.detail === 'string'
        ? run.terminalResult.detail
        : run.terminalCode ?? undefined,
    createdAt: new Date(run.createdAt),
    completedAt: run.terminalAt ? new Date(run.terminalAt) : undefined,
    chatHistory: [],
  };
}
