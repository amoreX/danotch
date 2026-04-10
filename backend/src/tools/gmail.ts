import { Composio } from '@composio/core';
import { AnthropicProvider } from '@composio/anthropic';
import type Anthropic from '@anthropic-ai/sdk';
import { config } from '../config.js';

// Gmail actions we expose to the chat agent
const GMAIL_TOOLS = [
  'GMAIL_FETCH_EMAILS',
  'GMAIL_SEND_EMAIL',
  'GMAIL_CREATE_EMAIL_DRAFT',
  'GMAIL_REPLY_TO_THREAD',
  'GMAIL_GET_PROFILE',
  'GMAIL_FETCH_MESSAGE_BY_MESSAGE_ID',
  'GMAIL_LIST_LABELS',
  'GMAIL_ADD_LABEL_TO_EMAIL',
];

let composio: InstanceType<typeof Composio> | null = null;

function getComposio() {
  if (!composio) {
    if (!config.composio.apiKey) {
      throw new Error('COMPOSIO_API_KEY not set');
    }
    composio = new Composio({
      apiKey: config.composio.apiKey,
      provider: new AnthropicProvider(),
    }) as any;
  }
  return composio!;
}

export function isComposioConfigured(): boolean {
  return !!config.composio.apiKey;
}

// ── Connection Management ──

export async function getGmailConnectionStatus(userId: string): Promise<{
  connected: boolean;
  accountId?: string;
  status?: string;
}> {
  try {
    const c = getComposio();
    const result = await c.connectedAccounts.list({
      userIds: [userId],
      toolkitSlugs: ['gmail'],
      statuses: ['ACTIVE'],
    });
    const gmail = result.items?.[0];
    if (gmail) {
      return { connected: true, accountId: gmail.id, status: gmail.status };
    }
    return { connected: false };
  } catch (err) {
    console.error('[gmail] Connection status check failed:', err);
    return { connected: false };
  }
}

export async function initiateGmailConnection(userId: string): Promise<{
  redirectUrl?: string;
  error?: string;
}> {
  try {
    const c = getComposio();

    // Get auth configs for Gmail
    const authConfigs = await (c as any).authConfigs.list({ toolkitSlugs: ['gmail'] });
    const gmailConfig = authConfigs?.items?.[0] ?? authConfigs?.[0];

    if (!gmailConfig?.id) {
      return { error: 'No Gmail auth config found. Set up Gmail in your Composio dashboard first.' };
    }

    const connectionRequest = await c.connectedAccounts.initiate(
      userId,
      gmailConfig.id,
      {
        callbackUrl: `http://localhost:${config.port}/api/gmail/callback`,
      }
    );

    // The connectionRequest should contain a redirectUrl for OAuth
    const redirectUrl = (connectionRequest as any).redirectUrl
      ?? (connectionRequest as any).redirect_url;

    if (!redirectUrl) {
      // Try waiting briefly — some flows auto-connect (API key based)
      try {
        await connectionRequest.waitForConnection(5000);
        return {}; // connected without redirect
      } catch {
        return { error: 'Could not get OAuth redirect URL from Composio.' };
      }
    }

    return { redirectUrl };
  } catch (err: any) {
    console.error('[gmail] Connection initiation failed:', err);
    return { error: err.message || 'Failed to initiate Gmail connection' };
  }
}

export async function disconnectGmail(userId: string): Promise<boolean> {
  try {
    const c = getComposio();
    const result = await c.connectedAccounts.list({
      userIds: [userId],
      toolkitSlugs: ['gmail'],
    });
    const gmail = result.items?.[0];
    if (gmail?.id) {
      await c.connectedAccounts.delete(gmail.id);
      return true;
    }
    return false;
  } catch (err) {
    console.error('[gmail] Disconnect failed:', err);
    return false;
  }
}

// ── Tool Fetching ──

export async function getGmailTools(userId: string): Promise<Anthropic.Tool[]> {
  try {
    const c = getComposio();
    const tools = await c.tools.get(userId, { tools: GMAIL_TOOLS });
    return (tools ?? []) as unknown as Anthropic.Tool[];
  } catch (err) {
    console.error('[gmail] Failed to fetch tools:', err);
    return [];
  }
}

// ── Tool Execution ──

export async function executeGmailTool(
  userId: string,
  toolCall: { id: string; function: { name: string; arguments: string } },
): Promise<string> {
  try {
    const c = getComposio();
    const result = await (c as any).provider.executeToolCall(userId, toolCall, {});
    return typeof result === 'string' ? result : JSON.stringify(result);
  } catch (err: any) {
    console.error('[gmail] Tool execution failed:', err);
    return JSON.stringify({ error: err.message || 'Gmail tool execution failed' });
  }
}
