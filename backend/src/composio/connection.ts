import { getComposio, isComposioConfigured } from './client.js';
import { getAdminDb } from '../lib/admin-db.js';
import { userDb } from '../lib/user-db.js';
import { config } from '../config.js';
import { createConnectionLink } from './link-adapter.js';

const supabase = new Proxy({} as ReturnType<typeof getAdminDb>, {
  get(_target, property) {
    const client = getAdminDb('reconciliation') as unknown as Record<PropertyKey, unknown>;
    const value = client[property];
    return typeof value === 'function' ? value.bind(client) : value;
  },
});

export { isComposioConfigured };

export async function getConnectionStatus(userId: string, toolkitSlug: string): Promise<{
  connected: boolean;
  available: boolean;
  accountId?: string;
  accountIds?: string[];
  status?: string;
}> {
  try {
    const c = getComposio();
    // Only an ACTIVE account is tool-usable. A pending/initiated/failed account
    // must NOT be reported as connected or synced as active — doing so exposes
    // tools that will fail at call time.
    const result = await c.connectedAccounts.list({
      userIds: [userId],
      toolkitSlugs: [toolkitSlug],
      statuses: ['ACTIVE'],
    } as any);
    const account = result.items?.[0];
    if (account && account.status === 'ACTIVE') {
      return {
        connected: true,
        available: true,
        accountId: account.id,
        accountIds: (result.items ?? []).map((item) => item.id).filter(Boolean),
        status: account.status,
      };
    }
    // Surface a non-active account's status for logging, but not as connected.
    const anyResult = await c.connectedAccounts.list({ userIds: [userId], toolkitSlugs: [toolkitSlug] } as any);
    const pending = anyResult.items?.[0];
    return { connected: false, available: true, status: pending?.status };
  } catch (err) {
    console.error(`[composio:${toolkitSlug}] Connection status check failed:`, err);
    return { connected: false, available: false, status: 'unknown' };
  }
}

export async function initiateConnection(
  userId: string,
  toolkitSlug: string,
  appType: string,
  callbackUrl?: string,
): Promise<{ redirectUrl?: string; error?: string }> {
  try {
    const c = getComposio();

    // Validate an auth config exists BEFORE deleting any existing account.
    // Destroying a working connection and then failing to initiate a new one
    // would leave the user disconnected (audit finding).
    const authConfigs = await (c as any).authConfigs.list({ toolkitSlugs: [toolkitSlug] });
    const allConfigs = authConfigs?.items ?? authConfigs ?? [];
    console.log(`[composio:${toolkitSlug}] Auth configs found:`, allConfigs.map((c: any) => ({ id: c.id, appName: c.appName })));
    const pinnedConfigId = config.composio.authConfigIds[
      appType as keyof typeof config.composio.authConfigIds
    ];
    // Production selects one reviewed auth configuration with minimum scopes
    // by immutable identifier. Runtime discovery is development-only.
    const appConfig = pinnedConfigId
      ? allConfigs.find((candidate: any) => candidate.id === pinnedConfigId)
      : allConfigs.find((candidate: any) => candidate.appName === toolkitSlug) ?? allConfigs[0];

    if (!appConfig?.id) {
      return { error: `No auth config found for ${toolkitSlug}. Set it up in your Composio dashboard first.` };
    }
    console.log(`[composio:${toolkitSlug}] Using auth config: ${appConfig.id} (appName: ${appConfig.appName})`);

    if (!config.publicBaseUrl) {
      return { error: 'PUBLIC_BASE_URL is required to create integration links.' };
    }
    if (config.isProduction && !config.publicBaseUrl.startsWith('https://')) {
      return { error: 'PUBLIC_BASE_URL must use HTTPS in production.' };
    }
    const exactCallbackUrl = callbackUrl
      ?? new URL(`/api/apps/${appType}/callback`, config.publicBaseUrl).toString();
    if (config.isProduction && !exactCallbackUrl.startsWith('https://')) {
      return { error: 'OAuth callback must use HTTPS in production.' };
    }

    // Link in parallel with any existing ACTIVE account. U6 will reconcile and
    // retire superseded accounts only after the replacement is confirmed.
    const connectionRequest = await createConnectionLink(
      c,
      userId,
      appConfig.id,
      exactCallbackUrl,
    );

    const redirectUrl = (connectionRequest as any).redirectUrl
      ?? (connectionRequest as any).redirect_url;

    if (!redirectUrl) {
      try {
        await connectionRequest.waitForConnection(5000);
        // Auto-connected — sync DB
        if (!await syncConnectionToDb(userId, appType, toolkitSlug)) {
          return { error: 'Connection was established but could not be persisted.' };
        }
        return {};
      } catch {
        return { error: 'Could not get OAuth redirect URL from Composio.' };
      }
    }

    return { redirectUrl };
  } catch (err: any) {
    console.error(`[composio:${toolkitSlug}] Connection initiation failed:`, err);
    return { error: err.message || `Failed to initiate ${toolkitSlug} connection` };
  }
}

export async function disconnect(userId: string, toolkitSlug: string, appType: string): Promise<boolean> {
  try {
    const c = getComposio();
    const result = await c.connectedAccounts.list({
      userIds: [userId],
      toolkitSlugs: [toolkitSlug],
    });
    // Delete ALL connected accounts (not just the first) to clear duplicates
    for (const account of result.items ?? []) {
      if (account?.id) {
        await c.connectedAccounts.delete(account.id);
      }
    }

    await supabase
      .from('danotch_connected_apps')
      .update({
        active: false,
        composio_conn_id: null,
        disconnected_at: new Date().toISOString(),
      })
      .eq('user_id', userId)
      .eq('app_type', appType);
    invalidateActiveAppsCache(userId);

    return true;
  } catch (err) {
    console.error(`[composio:${toolkitSlug}] Disconnect failed:`, err);
    return false;
  }
}

export async function retireSupersededAccount(
  userId: string,
  toolkitSlug: string,
  accountId: string,
): Promise<void> {
  const c = getComposio();
  const result = await c.connectedAccounts.list({
    userIds: [userId],
    toolkitSlugs: [toolkitSlug],
  });
  if ((result.items ?? []).some((account) => account.id === accountId)) {
    await c.connectedAccounts.delete(accountId);
  }
}

/**
 * Sync Composio connection state to the local connected_apps table.
 * Called after OAuth callback and after auto-connect.
 */
export async function syncConnectionToDb(
  userId: string,
  appType: string,
  toolkitSlug: string,
  confirmedAccountId?: string,
): Promise<boolean> {
  try {
    const status = await getConnectionStatus(userId, toolkitSlug);
    if (!status.available || !status.connected) return false;
    if (
      confirmedAccountId
      && !(status.accountIds ?? []).includes(confirmedAccountId)
    ) {
      return false;
    }
    const accountId = confirmedAccountId ?? status.accountId;
    if (!accountId) return false;
    const { error } = await supabase
        .from('danotch_connected_apps')
        .update({
          active: true,
          composio_conn_id: accountId,
          connected_at: new Date().toISOString(),
          disconnected_at: null,
        })
        .eq('user_id', userId)
        .eq('app_type', appType);
    if (error) return false;
    invalidateActiveAppsCache(userId);
    console.log(`[composio:${appType}] Synced connection to DB for user ${userId}`);
    return true;
  } catch (err) {
    console.error(`[composio:${appType}] Failed to sync connection to DB:`, err);
    return false;
  }
}

// Per-user cache for active apps — avoids hitting Supabase on every chat message
const activeAppsCache = new Map<string, { apps: string[]; expiresAt: number }>();
const CACHE_TTL_MS = 3 * 60 * 60 * 1000; // 3 hours

export function invalidateActiveAppsCache(userId: string) {
  activeAppsCache.delete(userId);
}

export async function getActiveApps(userId: string): Promise<string[]> {
  const cached = activeAppsCache.get(userId);
  if (cached && Date.now() < cached.expiresAt) {
    return cached.apps;
  }

  const { data, error } = await userDb
    .from('danotch_connected_apps')
    .select('app_type')
    .eq('user_id', userId)
    .eq('active', true);

  if (error) {
    console.error('[composio] Failed to query active apps:', error.message);
    return [];
  }

  const apps = (data ?? []).map((row) => row.app_type);
  activeAppsCache.set(userId, { apps, expiresAt: Date.now() + CACHE_TTL_MS });
  return apps;
}
