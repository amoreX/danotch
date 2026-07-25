import { Composio, OpenAIProvider } from '@composio/core';
import type { CanonicalTool } from '../providers/types.js';
import type { SecretBroker } from '../ipc/keychain-broker.js';
import {
  ACTION_REGISTRY,
  classifyAction,
  ACTION_REGISTRY_VERSION,
} from '../actions/registry.js';
import type { IntegrationType, Repositories } from '../db/repositories.js';

export const COMPOSIO_APPS = [
  { appType: 'gmail', toolkitSlug: 'gmail', prefix: 'GMAIL_', displayName: 'Gmail' },
  {
    appType: 'googlecalendar',
    toolkitSlug: 'googlecalendar',
    prefix: 'GOOGLECALENDAR_',
    displayName: 'Google Calendar',
  },
  { appType: 'googledocs', toolkitSlug: 'googledocs', prefix: 'GOOGLEDOCS_', displayName: 'Google Docs' },
  { appType: 'github', toolkitSlug: 'github', prefix: 'GITHUB_', displayName: 'GitHub' },
] as const;

export type ComposioApp = typeof COMPOSIO_APPS[number];

export interface ComposioClient {
  connectedAccounts: {
    list(input: Record<string, unknown>): Promise<{ items?: Array<{ id?: string; status?: string }> }>;
    link(userId: string, authConfigId: string, options?: Record<string, never>): Promise<{
      redirectUrl?: string | null;
      redirect_url?: string | null;
      waitForConnection?(timeout?: number): Promise<unknown>;
    }>;
    delete(id: string): Promise<unknown>;
  };
  authConfigs: {
    list(input: Record<string, unknown>): Promise<{ items?: Array<{ id?: string }> } | Array<{ id?: string }>>;
  };
  tools: {
    get(userId: string, input: { tools: string[] }): Promise<unknown[]>;
  };
  provider: {
    handleToolCalls(userId: string, message: unknown): Promise<unknown>;
  };
}

export type ComposioClientFactory = (apiKey: string) => ComposioClient;

const defaultFactory: ComposioClientFactory = (apiKey) => new Composio({
  apiKey,
  provider: new OpenAIProvider(),
  toolkitVersions: {
    gmail: 'latest',
    googlecalendar: 'latest',
    googledocs: 'latest',
    github: 'latest',
  },
}) as unknown as ComposioClient;

export class LocalComposioService {
  private readonly activeCache = new Map<IntegrationType, { active: boolean; expires: number }>();

  constructor(
    private readonly repositories: Repositories,
    private readonly broker: SecretBroker,
    private readonly factory: ComposioClientFactory = defaultFactory,
  ) {}

  async configured(): Promise<boolean> {
    return Boolean(await this.broker.getCredential('composio'));
  }

  metadata(): {
    local_user_id: string;
    integrations: Array<Record<string, unknown>>;
  } {
    const userId = this.repositories.getOrCreateComposioUserId();
    return {
      local_user_id: userId,
      integrations: COMPOSIO_APPS.map((app) => {
        const config = this.repositories.getIntegrationConfig(app.appType);
        return {
          app_type: app.appType,
          toolkit_slug: app.toolkitSlug,
          display_name: app.displayName,
          auth_config_id: config?.auth_config_id ?? null,
        };
      }),
    };
  }

  saveAuthConfigs(value: unknown): void {
    if (!value || typeof value !== 'object' || Array.isArray(value)) return;
    for (const app of COMPOSIO_APPS) {
      const candidate = (value as Record<string, unknown>)[app.appType];
      if (candidate !== undefined && (
        typeof candidate !== 'string'
        || candidate.length === 0
        || candidate.length > 256
      )) throw new Error(`Invalid auth config id for ${app.appType}`);
      this.repositories.saveIntegrationConfig(
        app.appType,
        app.toolkitSlug,
        typeof candidate === 'string'
          ? candidate
          : this.repositories.getIntegrationConfig(app.appType)?.auth_config_id ?? null,
      );
    }
  }

  async status(appType: string): Promise<{
    app_type: string;
    connected: boolean;
    status: string;
    available: boolean;
    account_ids: string[];
  }> {
    const app = findApp(appType);
    const client = await this.client();
    if (!client) {
      return {
        app_type: app.appType, connected: false, status: 'not_configured',
        available: false, account_ids: [],
      };
    }
    try {
      const userId = this.repositories.getOrCreateComposioUserId();
      const result = await client.connectedAccounts.list({
        userIds: [userId],
        toolkitSlugs: [app.toolkitSlug],
      });
      const accounts = result.items ?? [];
      const active = accounts.filter((item) => item.status === 'ACTIVE');
      const connected = active.length > 0;
      const status = connected ? 'ACTIVE' : accounts[0]?.status ?? 'disconnected';
      this.repositories.saveConnection(
        app.appType,
        connected ? 'connected' : status.toLowerCase(),
        active[0]?.id ?? null,
        { account_ids: active.map((item) => item.id).filter(Boolean) },
      );
      this.activeCache.set(app.appType, { active: connected, expires: Date.now() + 30_000 });
      return {
        app_type: app.appType,
        connected,
        status,
        available: true,
        account_ids: active.map((item) => item.id).filter((id): id is string => Boolean(id)),
      };
    } catch {
      return {
        app_type: app.appType, connected: false, status: 'unknown',
        available: false, account_ids: [],
      };
    }
  }

  async connect(appType: string): Promise<Record<string, unknown>> {
    const app = findApp(appType);
    const client = await this.requireClient();
    const userId = this.repositories.getOrCreateComposioUserId();
    const current = await this.status(app.appType);
    if (current.connected) return { connected: true, status: 'ACTIVE', already_connected: true };
    let authConfigId = this.repositories.getIntegrationConfig(app.appType)?.auth_config_id;
    if (!authConfigId) {
      const response = await client.authConfigs.list({ toolkitSlugs: [app.toolkitSlug] });
      const items = Array.isArray(response) ? response : response.items ?? [];
      authConfigId = items[0]?.id ?? null;
      if (!authConfigId) throw new Error(`No auth config configured for ${app.displayName}`);
      this.repositories.saveIntegrationConfig(app.appType, app.toolkitSlug, authConfigId);
    }
    // Current SDK hosted links own their completion page; no daemon callback is
    // supplied, so localhost and app secrets never become OAuth redirect state.
    const request = await client.connectedAccounts.link(userId, authConfigId);
    const redirectUrl = request.redirectUrl ?? request.redirect_url ?? undefined;
    if (redirectUrl) {
      this.repositories.saveConnection(app.appType, 'pending', null, { auth_config_id: authConfigId });
      this.activeCache.delete(app.appType);
      return { connected: false, status: 'pending', redirect_url: redirectUrl, redirectUrl };
    }
    if (request.waitForConnection) {
      try {
        await request.waitForConnection(5_000);
      } catch {
        // Truth comes from the status API below, never from link initiation.
      }
    }
    return this.status(app.appType);
  }

  async disconnect(appType: string): Promise<{ disconnected: boolean; deleted_accounts: number }> {
    const app = findApp(appType);
    const client = await this.requireClient();
    const userId = this.repositories.getOrCreateComposioUserId();
    const result = await client.connectedAccounts.list({
      userIds: [userId],
      toolkitSlugs: [app.toolkitSlug],
    });
    let deleted = 0;
    for (const account of result.items ?? []) {
      if (!account.id) continue;
      await client.connectedAccounts.delete(account.id);
      deleted += 1;
    }
    this.repositories.clearConnection(app.appType);
    this.activeCache.delete(app.appType);
    return { disconnected: true, deleted_accounts: deleted };
  }

  async loadTools(): Promise<{ tools: CanonicalTool[]; names: Set<string> }> {
    const client = await this.client();
    if (!client) return { tools: [], names: new Set() };
    const userId = this.repositories.getOrCreateComposioUserId();
    const tools: CanonicalTool[] = [];
    for (const app of COMPOSIO_APPS) {
      const cached = this.activeCache.get(app.appType);
      const active = cached && cached.expires > Date.now()
        ? cached.active
        : (await this.status(app.appType)).connected;
      if (!active) continue;
      const actionNames = [...ACTION_REGISTRY.keys()].filter((name) => name.startsWith(app.prefix));
      const fetched = await client.tools.get(userId, { tools: actionNames });
      for (const item of fetched as Array<Record<string, unknown>>) {
        const definition = item.type === 'function'
          && item.function
          && typeof item.function === 'object'
          ? item.function as Record<string, unknown>
          : item;
        const name = typeof definition.name === 'string'
          ? definition.name
          : typeof definition.slug === 'string'
            ? definition.slug
            : undefined;
        const description = definition.description;
        const inputSchema = definition.parameters ?? definition.inputParameters ?? definition.input_schema;
        if (
          typeof name === 'string'
          && typeof description === 'string'
          && inputSchema && typeof inputSchema === 'object'
          && ACTION_REGISTRY.has(name)
        ) {
          tools.push({
            name,
            description,
            input_schema: inputSchema as CanonicalTool['input_schema'],
          });
        }
      }
    }
    return { tools, names: new Set(tools.map((tool) => tool.name)) };
  }

  policy(toolName: string): 'read' | 'approval' {
    const decision = classifyAction(toolName, {
      registryVersion: ACTION_REGISTRY_VERSION,
      metadataValidated: true,
    });
    if (decision.kind === 'read' || decision.kind === 'approval') return decision.kind;
    throw new Error(`Composio action denied: ${'reason' in decision ? decision.reason : 'invalid_policy'}`);
  }

  async execute(toolName: string, input: Record<string, unknown>, id: string): Promise<string> {
    if (!ACTION_REGISTRY.has(toolName)) throw new Error('Composio action is not allowlisted');
    const client = await this.requireClient();
    const message = {
      id: 'chatcmpl_local_tool',
      object: 'chat.completion',
      created: Math.floor(Date.now() / 1_000),
      model: 'perch-local-tool-router',
      choices: [{
        index: 0,
        finish_reason: 'tool_calls',
        logprobs: null,
        message: {
          role: 'assistant',
          content: null,
          refusal: null,
          tool_calls: [{
            id,
            type: 'function',
            function: {
              name: toolName,
              arguments: JSON.stringify(input),
            },
          }],
        },
      }],
      usage: {
        prompt_tokens: 0,
        completion_tokens: 0,
        total_tokens: 0,
      },
    };
    const response = await client.provider.handleToolCalls(
      this.repositories.getOrCreateComposioUserId(),
      message,
    );
    const first = Array.isArray(response) ? response[0] : response;
    const content = first && typeof first === 'object' && 'content' in first
      ? (first as { content: unknown }).content
      : first;
    return (typeof content === 'string' ? content : JSON.stringify(content ?? {
      error: 'No result from Composio',
    })).slice(0, 8_000);
  }

  private async client(): Promise<ComposioClient | undefined> {
    const apiKey = await this.broker.getCredential('composio');
    return apiKey ? this.factory(apiKey) : undefined;
  }

  private async requireClient(): Promise<ComposioClient> {
    const value = await this.client();
    if (!value) throw new Error('Composio is not configured');
    return value;
  }
}

function findApp(value: string): ComposioApp {
  const app = COMPOSIO_APPS.find((candidate) => candidate.appType === value);
  if (!app) throw new Error('Unsupported integration');
  return app;
}
