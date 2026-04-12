import { getComposio, isComposioConfigured } from './client.js';
import { supabase } from '../lib/supabase.js';
import { config } from '../config.js';

export { isComposioConfigured };

export async function getConnectionStatus(userId: string, toolkitSlug: string): Promise<{
  connected: boolean;
  accountId?: string;
  status?: string;
}> {
  try {
    const c = getComposio();
    const result = await c.connectedAccounts.list({
      userIds: [userId],
      toolkitSlugs: [toolkitSlug],
      statuses: ['ACTIVE'],
    });
    const account = result.items?.[0];
    if (account) {
      return { connected: true, accountId: account.id, status: account.status };
    }
    return { connected: false };
  } catch (err) {
    console.error(`[composio:${toolkitSlug}] Connection status check failed:`, err);
    return { connected: false };
  }
}

export async function initiateConnection(
  userId: string,
  toolkitSlug: string,
  appType: string,
): Promise<{ redirectUrl?: string; error?: string }> {
  try {
    const c = getComposio();

    const authConfigs = await (c as any).authConfigs.list({ toolkitSlugs: [toolkitSlug] });
    const appConfig = authConfigs?.items?.[0] ?? authConfigs?.[0];

    if (!appConfig?.id) {
      return { error: `No auth config found for ${toolkitSlug}. Set it up in your Composio dashboard first.` };
    }

    const connectionRequest = await c.connectedAccounts.initiate(
      userId,
      appConfig.id,
      {
        callbackUrl: `http://localhost:${config.port}/api/apps/${appType}/callback`,
      }
    );

    const redirectUrl = (connectionRequest as any).redirectUrl
      ?? (connectionRequest as any).redirect_url;

    if (!redirectUrl) {
      try {
        await connectionRequest.waitForConnection(5000);
        // Auto-connected — sync DB
        await syncConnectionToDb(userId, appType, toolkitSlug);
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
    const account = result.items?.[0];
    if (account?.id) {
      await c.connectedAccounts.delete(account.id);
    }

    // Sync disconnect to local DB
    await supabase
      .from('connected_apps')
      .update({
        active: false,
        composio_conn_id: null,
        disconnected_at: new Date().toISOString(),
      })
      .eq('user_id', userId)
      .eq('app_type', appType);

    return true;
  } catch (err) {
    console.error(`[composio:${toolkitSlug}] Disconnect failed:`, err);
    return false;
  }
}

/**
 * Sync Composio connection state to the local connected_apps table.
 * Called after OAuth callback and after auto-connect.
 */
export async function syncConnectionToDb(userId: string, appType: string, toolkitSlug: string): Promise<void> {
  try {
    const status = await getConnectionStatus(userId, toolkitSlug);
    if (status.connected) {
      await supabase
        .from('connected_apps')
        .update({
          active: true,
          composio_conn_id: status.accountId ?? null,
          connected_at: new Date().toISOString(),
          disconnected_at: null,
        })
        .eq('user_id', userId)
        .eq('app_type', appType);
      console.log(`[composio:${appType}] Synced connection to DB for user ${userId}`);
    }
  } catch (err) {
    console.error(`[composio:${appType}] Failed to sync connection to DB:`, err);
  }
}

/**
 * Get all active app connections for a user from the local DB.
 * Much faster than hitting Composio API for each app.
 */
export async function getActiveApps(userId: string): Promise<string[]> {
  const { data, error } = await supabase
    .from('connected_apps')
    .select('app_type')
    .eq('user_id', userId)
    .eq('active', true);

  if (error) {
    console.error('[composio] Failed to query active apps:', error.message);
    return [];
  }
  return (data ?? []).map((row) => row.app_type);
}
