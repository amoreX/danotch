import { randomUUID } from 'node:crypto';
import type { Config } from '../config.js';
import type { Repositories } from '../db/repositories.js';
import type { NotchBridge } from '../events/notch.js';
import type { SecretBroker } from '../ipc/keychain-broker.js';
import { resolveProvider } from '../providers/factory.js';
import type {
  CanonicalContentBlock,
  CanonicalMessage,
  CanonicalToolResultBlock,
} from '../providers/types.js';
import { executeHostedTool, hostedTools } from '../tools/local.js';
import { scheduledTaskTools, executeScheduledTool } from '../tools/scheduled.js';
import { localActionTools, executeLocalActionTool } from '../tools/local-actions.js';
import type { ActionCoordinator } from '../actions/coordinator.js';
import type { LocalComposioService } from '../composio/service.js';
import { ACTION_REGISTRY_VERSION } from '../actions/registry.js';
import type { CanonicalTool } from '../providers/types.js';

const connectionTool: CanonicalTool = {
  name: 'request_app_connection',
  description: 'Ask the user to connect Gmail, Google Calendar, Google Docs, or GitHub.',
  input_schema: {
    type: 'object',
    properties: {
      app_type: {
        type: 'string',
        enum: ['gmail', 'googlecalendar', 'googledocs', 'github'],
      },
      reason: { type: 'string', description: 'Why this connection is needed.' },
    },
    required: ['app_type', 'reason'],
  },
};

export interface RunChatInput {
  message: string;
  sessionId?: string;
  conversationId?: string;
  providerId?: string;
  modelId?: string;
  baseUrl?: string;
  history?: { role: 'user' | 'assistant'; content: string }[];
}

export async function runChat(
  input: RunChatInput,
  dependencies: {
    repositories: Repositories;
    broker: SecretBroker;
    events: NotchBridge;
    config: Config;
    actions: ActionCoordinator;
    composio: LocalComposioService;
  },
): Promise<{ id: string; status: 'completed' | 'failed'; result?: string; error?: string; conversationId: string }> {
  const { repositories, broker, events, config } = dependencies;
  const sessionId = input.sessionId ?? randomUUID();
  const conversationId = input.conversationId ?? sessionId;
  const preference = repositories.getProvider(input.providerId);
  if (!preference) throw new Error(input.providerId ? 'Provider not found' : 'No active provider configured');

  const provider = await resolveProvider(preference, broker, {
    modelId: input.modelId,
    baseUrl: input.baseUrl,
  });
  repositories.ensureConversation(conversationId, preference.id, input.modelId, input.baseUrl);
  repositories.addMessage(conversationId, 'user', input.message);
  const runId = repositories.createRun({
    kind: 'chat',
    conversationId,
    providerId: preference.id,
    modelId: input.modelId ?? preference.model_id,
    input: { message: input.message },
  });
  repositories.updateRun(runId, 'running');
  events.sendStatus(sessionId, {
    task: input.message,
    description: input.message.slice(0, 80),
    status: 'running',
    tool_calls_count: 0,
  });

  const messages: CanonicalMessage[] = [
    ...(input.history ?? []).slice(-24),
    { role: 'user', content: input.message },
  ];
  let completeText = '';
  let toolCount = 0;
  const composioTools = await dependencies.composio.loadTools();
  const allTools = [
    ...hostedTools,
    ...scheduledTaskTools,
    ...localActionTools,
    connectionTool,
    ...composioTools.tools,
  ];

  try {
    for (let loop = 0; loop < 5; loop += 1) {
      const result = await provider.stream({
        messages,
        tools: allTools,
        systemPrompt: config.systemPrompt,
        maxTokens: config.maxTokens,
        onText: (text) => {
          completeText += text;
          events.sendProgress(sessionId, { type: 'token', text });
        },
      });
      const toolUses = result.content.filter(
        (block): block is Extract<CanonicalContentBlock, { type: 'tool_use' }> =>
          block.type === 'tool_use',
      );
      if (toolUses.length === 0) {
        const text = result.content
          .filter((block): block is Extract<CanonicalContentBlock, { type: 'text' }> => block.type === 'text')
          .map((block) => block.text)
          .join('') || completeText;
        repositories.addMessage(conversationId, 'assistant', text, {
          provider: provider.providerName,
          model: provider.modelId,
          usage: result.usage,
        });
        repositories.updateRun(runId, 'completed', text);
        repositories.addRunEvent(runId, 'run_completed', { usage: result.usage, toolCount });
        events.sendDone(sessionId, { status: 'completed', result: text });
        return { id: runId, status: 'completed', result: text, conversationId };
      }

      const flushed = result.content
        .filter((block): block is Extract<CanonicalContentBlock, { type: 'text' }> => block.type === 'text')
        .map((block) => block.text)
        .join('');
      if (flushed) events.sendProgress(sessionId, { type: 'text_flush', text: flushed });
      completeText = '';
      messages.push({ role: 'assistant', content: result.content });
      const toolResults: CanonicalToolResultBlock[] = [];
      for (const tool of toolUses) {
        toolCount += 1;
        const summary = summarizeTool(tool.name, tool.input);
        events.sendProgress(sessionId, {
          type: 'tool_start',
          tool_name: tool.name,
          tool_input: summary,
        });
        const output = await executeTool(tool.name, tool.input, {
          ...dependencies,
          runId,
          sessionId,
          preference,
          modelId: input.modelId,
          baseUrl: input.baseUrl,
          composioNames: composioTools.names,
        });
        const preview = output.slice(0, 300);
        events.sendProgress(sessionId, {
          type: 'tool_result',
          tool_name: tool.name,
          tool_input: summary,
          tool_output: preview,
        });
        repositories.addMessage(conversationId, 'tool', preview, { name: tool.name });
        repositories.addRunEvent(runId, 'tool_result', { name: tool.name });
        toolResults.push({
          type: 'tool_result',
          tool_use_id: tool.id,
          content: output.slice(0, 8_000),
        });
      }
      messages.push({ role: 'user', content: toolResults });
    }
    throw new Error('Maximum tool iterations reached');
  } catch {
    const message = 'The request could not be completed.';
    repositories.updateRun(runId, 'failed', null, message);
    repositories.addRunEvent(runId, 'run_failed', { code: 'provider_or_tool_failure' });
    events.sendDone(sessionId, { status: 'failed', error: message });
    return { id: runId, status: 'failed', error: message, conversationId };
  }
}

async function executeTool(
  name: string,
  input: Record<string, unknown>,
  context: {
    repositories: Repositories;
    events: NotchBridge;
    config: Config;
    actions: ActionCoordinator;
    composio: LocalComposioService;
    runId: string;
    sessionId: string;
    preference: NonNullable<ReturnType<Repositories['getProvider']>>;
    modelId?: string;
    baseUrl?: string;
    composioNames: Set<string>;
  },
): Promise<string> {
  if (hostedTools.some((tool) => tool.name === name)) return executeHostedTool(name, input);
  if (scheduledTaskTools.some((tool) => tool.name === name)) {
    return executeScheduledTool(name, input, {
      repositories: context.repositories,
      config: context.config,
      pinnedProvider: context.preference,
      modelId: context.modelId,
      baseUrl: context.baseUrl,
    });
  }
  if (name === 'bash_execute') {
    return executeLocalActionTool(input, {
      runId: context.runId,
      sessionId: context.sessionId,
      coordinator: context.actions,
    });
  }
  if (name === 'request_app_connection') {
    const appType = String(input.app_type ?? '');
    const app = ['gmail', 'googlecalendar', 'googledocs', 'github'].includes(appType)
      ? appType : undefined;
    if (!app || typeof input.reason !== 'string' || input.reason.length > 500) {
      throw new Error('Invalid connection request');
    }
    const requestId = randomUUID();
    const displayNames: Record<string, string> = {
      gmail: 'Gmail',
      googlecalendar: 'Google Calendar',
      googledocs: 'Google Docs',
      github: 'GitHub',
    };
    context.events.send({
      type: 'connection_request',
      request_id: requestId,
      session_id: context.sessionId,
      app_type: app,
      display_name: displayNames[app],
      reason: input.reason,
    });
    const approved = await context.actions.waitForConnectionResponse(requestId);
    return JSON.stringify(approved
      ? { approved: true, app_type: app, message: 'The local app started the hosted connection flow.' }
      : { approved: false, app_type: app, error: 'Connection request was denied or expired.' });
  }
  if (context.composioNames.has(name)) {
    if (context.composio.policy(name) === 'read') {
      return context.composio.execute(name, input, randomUUID());
    }
    const action = context.repositories.createPendingAction(
      context.runId,
      name,
      summarizeTool(name, input),
      input,
      {
        sessionId: context.sessionId,
        origin: 'composio',
        registryVersion: ACTION_REGISTRY_VERSION,
      },
    );
    context.events.sendPendingAction(
      action.id,
      context.sessionId,
      name,
      action.summary,
    );
    const terminal = await context.actions.waitForTerminal(action.id);
    if (terminal.status === 'completed') return terminal.result_json?.slice(0, 8_000) ?? '{}';
    return JSON.stringify({
      error: terminal.status === 'rejected'
        ? 'User rejected the integration action'
        : terminal.error ?? `Integration action ${terminal.status}`,
    });
  }
  throw new Error(`Tool ${name} is not registered`);
}

function summarizeTool(name: string, input: Record<string, unknown>): string {
  if (name === 'web_search') return String(input.query ?? '').slice(0, 160);
  if (name === 'web_fetch') return String(input.url ?? '').slice(0, 160);
  return JSON.stringify(input).slice(0, 160);
}
