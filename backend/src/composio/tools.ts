import type Anthropic from '@anthropic-ai/sdk';
import { getComposio, isComposioConfigured } from './client.js';
import { getActiveApps } from './connection.js';
import { GMAIL_TOOLS } from './apps/gmail.js';
import { GCAL_TOOLS } from './apps/gcal.js';
import { GDOCS_TOOLS } from './apps/gdocs.js';
import { GITHUB_TOOLS } from './apps/github.js';

export { isComposioConfigured };

// ── App Registry ──
// Maps app_type (DB column) → toolkit slug (Composio API) → tool action list

export interface ComposioApp {
  appType: string;       // DB connected_apps.app_type
  toolkitSlug: string;   // Composio toolkit slug
  tools: string[];       // Composio action names
  displayName: string;   // For logs and prompts
}

export const COMPOSIO_APPS: ComposioApp[] = [
  { appType: 'gmail', toolkitSlug: 'gmail', tools: GMAIL_TOOLS, displayName: 'Gmail' },
  { appType: 'googlecalendar', toolkitSlug: 'googlecalendar', tools: GCAL_TOOLS, displayName: 'Google Calendar' },
  { appType: 'googledocs', toolkitSlug: 'googledocs', tools: GDOCS_TOOLS, displayName: 'Google Docs' },
  { appType: 'github', toolkitSlug: 'github', tools: GITHUB_TOOLS, displayName: 'GitHub' },
];

// ── Tool Loading ──

/**
 * Load all Composio tools for a user's active app connections.
 * Queries local DB for active apps, then fetches tool schemas from Composio.
 * Returns the tools and a Set of tool names for routing.
 */
export async function loadComposioTools(userId: string): Promise<{
  tools: Anthropic.Tool[];
  toolNames: Set<string>;
  activeAppNames: string[];
}> {
  if (!isComposioConfigured()) {
    return { tools: [], toolNames: new Set(), activeAppNames: [] };
  }

  const activeAppTypes = await getActiveApps(userId);
  if (activeAppTypes.length === 0) {
    return { tools: [], toolNames: new Set(), activeAppNames: [] };
  }

  const allTools: Anthropic.Tool[] = [];
  const allToolNames = new Set<string>();
  const activeAppNames: string[] = [];

  for (const app of COMPOSIO_APPS) {
    if (!activeAppTypes.includes(app.appType)) continue;

    try {
      const tools = await getToolsForApp(userId, app.tools);
      if (tools.length > 0) {
        allTools.push(...tools);
        tools.forEach(t => allToolNames.add(t.name));
        activeAppNames.push(app.displayName);
        console.log(`[composio] ${app.displayName} tools loaded: ${tools.length}`);
      }
    } catch (err) {
      console.error(`[composio] Failed to load ${app.displayName} tools:`, err);
    }
  }

  return { tools: allTools, toolNames: allToolNames, activeAppNames };
}

/**
 * Load tools for a single app type. Used after a new connection is established mid-conversation.
 * Returns the tools and their names so the caller can merge them into the active tool set.
 */
export async function loadToolsForApp(userId: string, appType: string): Promise<{
  tools: Anthropic.Tool[];
  toolNames: Set<string>;
}> {
  const app = COMPOSIO_APPS.find(a => a.appType === appType);
  if (!app) return { tools: [], toolNames: new Set() };

  try {
    const tools = await getToolsForApp(userId, app.tools);
    const toolNames = new Set(tools.map(t => t.name));
    console.log(`[composio] ${app.displayName} tools loaded on-demand: ${tools.length}`);
    return { tools, toolNames };
  } catch (err) {
    console.error(`[composio] Failed to load ${app.displayName} tools on-demand:`, err);
    return { tools: [], toolNames: new Set() };
  }
}

// ── Toolkit version for a tool name (e.g. GMAIL_FETCH_EMAILS → gmail) ──

function getToolkitSlug(toolName: string): string | undefined {
  const prefix = toolName.split('_')[0]?.toLowerCase();
  if (!prefix) return undefined;
  return COMPOSIO_APPS.find(a => a.toolkitSlug === prefix
    || toolName.startsWith(a.toolkitSlug.toUpperCase()))?.toolkitSlug;
}

// ── Tool Fetching ──

async function getToolsForApp(userId: string, toolActions: string[]): Promise<Anthropic.Tool[]> {
  try {
    const c = getComposio();
    const tools = await c.tools.get(userId, { tools: toolActions });
    return (tools ?? []) as unknown as Anthropic.Tool[];
  } catch (err) {
    console.error('[composio] Failed to fetch tools:', err);
    return [];
  }
}

// ── Tool Execution ──

export async function executeComposioTool(
  userId: string,
  toolCall: { id: string; name: string; input: Record<string, unknown> },
): Promise<string> {
  try {
    const c = getComposio();

    // Use provider.handleToolCalls which handles toolkit versions automatically
    const fakeMessage = {
      id: 'msg_tool',
      type: 'message' as const,
      role: 'assistant' as const,
      model: '',
      content: [{
        type: 'tool_use' as const,
        id: toolCall.id,
        name: toolCall.name,
        input: toolCall.input,
      }],
      stop_reason: 'tool_use' as const,
      stop_sequence: null,
      usage: { input_tokens: 0, output_tokens: 0 },
    };

    const results = await (c as any).provider.handleToolCalls(userId, fakeMessage);
    if (Array.isArray(results) && results.length > 0) {
      const r = results[0];
      const content = r?.content ?? r;
      return typeof content === 'string' ? content : JSON.stringify(content);
    }
    return JSON.stringify({ error: 'No result from tool execution' });
  } catch (err: any) {
    console.error(`[composio] Tool execution failed (${toolCall.name}):`, err);
    return JSON.stringify({ error: err.message || 'Composio tool execution failed' });
  }
}
