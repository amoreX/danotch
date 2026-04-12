import { Router } from 'express';
import { requireAuth } from '../middleware/auth.js';
import {
  isComposioConfigured,
  getConnectionStatus,
  initiateConnection,
  disconnect,
  syncConnectionToDb,
} from '../composio/connection.js';
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

  // OAuth callback — Composio redirects here after user authorizes.
  // The userId comes as a query param that Composio passes through (entity_id).
  router.get('/callback', async (req, res) => {
    console.log(`${tag} OAuth callback received:`, req.query);

    // Composio passes the entity_id (our userId) back in the callback
    const userId = (req.query.entity_id as string) ?? (req.query.entityId as string);
    if (userId) {
      await syncConnectionToDb(userId, appType, toolkitSlug);
    }

    res.send(`
      <html>
        <body style="background:#000;color:#fff;font-family:system-ui;display:flex;align-items:center;justify-content:center;height:100vh;margin:0">
          <div style="text-align:center">
            <h1 style="font-size:48px;margin:0">✓</h1>
            <p style="color:#4A9E5C;font-size:18px;margin-top:12px">${displayName} connected successfully</p>
            <p style="color:#666;font-size:14px;margin-top:8px">You can close this tab and return to Danotch</p>
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
