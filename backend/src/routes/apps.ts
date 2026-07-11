import { Router } from 'express';
import { requireAuth } from '../middleware/auth.js';
import {
  isComposioConfigured,
  getConnectionStatus,
  initiateConnection,
  disconnect,
  syncConnectionToDb,
  invalidateActiveAppsCache,
} from '../composio/connection.js';
import { getComposio } from '../composio/client.js';
import { supabase } from '../lib/supabase.js';
import { COMPOSIO_APPS } from '../composio/tools.js';

/**
 * Create routes for a single Composio app integration.
 * Mounts at /api/apps/:appType with endpoints: /configured, /status, /connect, /disconnect, /callback
 */
function createSingleAppRoutes(appType: string, toolkitSlug: string, displayName: string): Router {
  const router = Router();
  const tag = `[apps:${appType}]`;

  router.get('/configured', (_req, res) => {
    res.json({ configured: isComposioConfigured() });
  });

  router.get('/status', requireAuth, async (req, res) => {
    const userId = req.user!.sub;
    console.log(`${tag} GET /status userId=${userId}`);

    if (!isComposioConfigured()) {
      res.json({ connected: false, reason: 'composio_not_configured' });
      return;
    }

    const status = await getConnectionStatus(userId, toolkitSlug);
    if (status.connected) {
      // Trusted, authenticated sync point: an ACTIVE Composio account is the
      // source of truth. Persist it so later chats (which load tools from the
      // DB) can use it. This is where redirect-OAuth completions become durable.
      await syncConnectionToDb(userId, appType, toolkitSlug);
      console.log(`${tag} → connected=true (synced to DB)`);
      res.json({ connected: true });
      return;
    }

    // Composio not reporting connected yet — fall back to a previously-synced
    // DB row so a brief post-OAuth lag doesn't flip the UI back to disconnected.
    const { data } = await supabase
      .from('danotch_connected_apps')
      .select('active')
      .eq('user_id', userId)
      .eq('app_type', appType)
      .single();
    if (data?.active) {
      console.log(`${tag} → connected=true (from DB, composio lagging)`);
      res.json({ connected: true });
      return;
    }
    console.log(`${tag} → connected=${status.connected}`);
    res.json(status);
  });

  router.post('/connect', requireAuth, async (req, res) => {
    const userId = req.user!.sub;
    console.log(`${tag} POST /connect userId=${userId}`);

    if (!isComposioConfigured()) {
      res.status(400).json({ error: 'COMPOSIO_API_KEY not set — add it to backend/.env' });
      return;
    }

    const existing = await getConnectionStatus(userId, toolkitSlug);
    if (existing.connected) {
      // Sync to DB in case it was out of sync
      await syncConnectionToDb(userId, appType, toolkitSlug);
      res.json({ already_connected: true });
      return;
    }

    const result = await initiateConnection(userId, toolkitSlug, appType);
    if (result.error) {
      console.log(`${tag} ✗ ${result.error}`);
      res.status(400).json({ error: result.error });
      return;
    }

    console.log(`${tag} → redirectUrl=${result.redirectUrl ? 'yes' : 'auto-connected'}`);
    res.json({ redirectUrl: result.redirectUrl, connected: !result.redirectUrl });
  });

  router.post('/disconnect', requireAuth, async (req, res) => {
    const userId = req.user!.sub;
    console.log(`${tag} POST /disconnect userId=${userId}`);

    const success = await disconnect(userId, toolkitSlug, appType);
    res.json({ ok: success });
  });

  router.post('/reset', requireAuth, async (req, res) => {
    const userId = req.user!.sub;
    console.log(`${tag} POST /reset userId=${userId}`);

    try {
      const c = getComposio();
      // App-scoped: only delete accounts for THIS app's toolkit. Resetting Gmail
      // must never remove the user's GitHub connection.
      const scoped = await c.connectedAccounts.list({ userIds: [userId], toolkitSlugs: [toolkitSlug] });
      let deleted = 0;
      for (const account of scoped.items ?? []) {
        if (account?.id) {
          try {
            await c.connectedAccounts.delete(account.id);
            deleted++;
            console.log(`${tag} Deleted composio account ${account.id}`);
          } catch (e: any) {
            console.warn(`${tag} Failed to delete account ${account.id}:`, e.message);
          }
        }
      }
      console.log(`${tag} Reset: deleted ${deleted} composio accounts for ${toolkitSlug}`);
    } catch (e: any) {
      console.warn(`${tag} Reset composio cleanup error:`, e.message);
    }

    // Clear DB state for this app
    await supabase
      .from('danotch_connected_apps')
      .update({ active: false, composio_conn_id: null, disconnected_at: new Date().toISOString() })
      .eq('user_id', userId)
      .eq('app_type', appType);

    invalidateActiveAppsCache(userId);
    res.json({ ok: true });
  });

  // OAuth callback — Composio redirects here after user authorizes.
  // This endpoint intentionally does NOT write to the database. Query parameters
  // are client-controlled and can be forged (e.g., an attacker could craft a
  // callback URL with another user's user_id). The macOS app polls
  // /api/apps/:appType/status, which queries Composio directly as the source of
  // truth, so the DB state is updated from a trusted source instead.
  router.get('/callback', async (_req, res) => {
    console.log(`${tag} OAuth callback received — rendering success page only`);

    res.send(`
      <html>
        <body style="background:#000;color:#fff;font-family:system-ui;display:flex;align-items:center;justify-content:center;height:100vh;margin:0">
          <div style="text-align:center">
            <h1 style="font-size:48px;margin:0">✓</h1>
            <p style="color:#4A9E5C;font-size:18px;margin-top:12px">${displayName} connected successfully</p>
            <p style="color:#666;font-size:14px;margin-top:8px">You can close this tab and return to Perch</p>
          </div>
        </body>
      </html>
    `);
  });

  return router;
}

/**
 * Create and mount all app routes from the registry.
 * Returns a router that mounts each app at /:appType/*
 */
export function createAppRoutes(): Router {
  const router = Router();

  for (const app of COMPOSIO_APPS) {
    router.use(`/${app.appType}`, createSingleAppRoutes(app.appType, app.toolkitSlug, app.displayName));
  }

  return router;
}
