import { Router } from 'express';
import { requireAuth } from '../middleware/auth.js';
import {
  isComposioConfigured,
  getConnectionStatus,
  initiateConnection,
  disconnect,
  syncConnectionToDb,
  invalidateActiveAppsCache,
  retireSupersededAccount,
} from '../composio/connection.js';
import { userDb as supabase } from '../lib/user-db.js';
import { getAdminDb } from '../lib/admin-db.js';
import { COMPOSIO_APPS } from '../composio/tools.js';
import { config } from '../config.js';
import {
  beginOAuthLinkAttempt,
  confirmOAuthReplacement,
  consumeOAuthCallback,
  failOAuthLinkAttempt,
  getOAuthAttempt,
} from '../composio/oauth-state.js';
import { SupabaseQuotaStore, requestQuotaSubject } from '../security/quota-store.js';

const oauthQuota = new SupabaseQuotaStore(getAdminDb('reconciliation'));

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
    let confirmedAccountId: string | undefined;
    let supersededAccountId: string | undefined;
    if (!status.available) {
      const { data } = await supabase
        .from('danotch_connected_apps')
        .select('active')
        .eq('user_id', userId)
        .eq('app_type', appType)
        .single();
      res.status(503).json({
        connected: Boolean(data?.active),
        stale: true,
        reason: 'provider_status_unavailable',
      });
      return;
    }
    const attemptId = typeof req.query.attempt_id === 'string' ? req.query.attempt_id : '';
    const deviceId = typeof req.query.device_id === 'string' ? req.query.device_id : '';
    if (attemptId && deviceId) {
      const attempt = await getOAuthAttempt({ attemptId, userId, deviceId, appType });
      if (!attempt || !attempt.callbackReceived) {
        res.json({ connected: status.connected, linking: true });
        return;
      }
      const candidateAccountIds = (status.accountIds ?? [])
        .filter((id) => id !== attempt.priorAccountId);
      if (candidateAccountIds.length > 1) {
        res.status(409).json({
          connected: Boolean(attempt.priorAccountId),
          reason: 'ambiguous_replacement_requires_reconciliation',
        });
        return;
      }
      const candidateAccountId = candidateAccountIds[0];
      if (!status.connected || !candidateAccountId) {
        res.json({ connected: Boolean(attempt.priorAccountId), linking: true });
        return;
      }
      const confirmed = await confirmOAuthReplacement({
        attemptId,
        userId,
        deviceId,
        appType,
        candidateAccountId,
      });
      if (!confirmed) {
        res.status(409).json({ connected: Boolean(attempt.priorAccountId), reason: 'stale_link_attempt' });
        return;
      }
      confirmedAccountId = candidateAccountId;
      supersededAccountId = attempt.priorAccountId;
    }
    if (status.connected) {
      // Trusted, authenticated sync point: an ACTIVE Composio account is the
      // source of truth. Persist it so later chats (which load tools from the
      // DB) can use it. This is where redirect-OAuth completions become durable.
      const persisted = await syncConnectionToDb(
        userId,
        appType,
        toolkitSlug,
        confirmedAccountId,
      );
      if (!persisted) {
        res.status(503).json({
          connected: Boolean(supersededAccountId),
          stale: true,
          reason: 'connection_persistence_unavailable',
        });
        return;
      }
      if (confirmedAccountId && supersededAccountId && confirmedAccountId !== supersededAccountId) {
        try {
          await retireSupersededAccount(userId, toolkitSlug, supersededAccountId);
        } catch {
          // The new account is already durable. Cleanup is reconciliation work;
          // never roll the user back to disconnected because provider cleanup
          // was temporarily unavailable.
        }
      }
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

    const deviceId = typeof req.body?.device_id === 'string' ? req.body.device_id : '';
    if (!deviceId) {
      res.status(400).json({ error: 'device_id is required for OAuth linking' });
      return;
    }
    const existing = await getConnectionStatus(userId, toolkitSlug);
    if (!existing.available) {
      res.status(503).json({ error: 'Connection status is temporarily unavailable.' });
      return;
    }
    if (existing.connected && req.body?.replace !== true) {
      // Sync to DB in case it was out of sync
      if (!await syncConnectionToDb(userId, appType, toolkitSlug)) {
        res.status(503).json({ error: 'Connection status could not be persisted.' });
        return;
      }
      res.json({ already_connected: true });
      return;
    }
    if (!config.containment.costlyIntegrationsEnabled) {
      res.status(503).json({
        error: 'New integration connections are temporarily unavailable.',
        code: 'costly_integrations_frozen',
      });
      return;
    }

    try {
      await oauthQuota.consume({
        capability: 'oauth',
        subject: requestQuotaSubject({ userId }),
      });
    } catch {
      res.status(503).json({ error: 'Integration linking is temporarily unavailable.' });
      return;
    }
    let attempt;
    try {
      attempt = await beginOAuthLinkAttempt({
        userId,
        deviceId,
        appType,
        toolkitSlug,
        callbackBaseUrl: config.publicBaseUrl,
        priorAccountId: existing.accountId,
        ttlMs: config.oauth.stateTtlMs,
      });
    } catch {
      res.status(503).json({ error: 'Integration linking is temporarily unavailable.' });
      return;
    }
    const result = await initiateConnection(userId, toolkitSlug, appType, attempt.callbackUrl);
    if (result.error) {
      await failOAuthLinkAttempt(attempt.id, userId);
      console.log(`${tag} ✗ ${result.error}`);
      res.status(503).json({ error: 'Integration linking could not be started. Try again.' });
      return;
    }

    console.log(`${tag} → redirectUrl=${result.redirectUrl ? 'yes' : 'auto-connected'}`);
    res.json({
      redirectUrl: result.redirectUrl,
      connected: !result.redirectUrl,
      attempt_id: attempt.id,
      expires_at: attempt.expiresAt,
      pkce: 'provider_managed',
    });
  });

  router.post('/disconnect', requireAuth, async (req, res) => {
    const userId = req.user!.sub;
    console.log(`${tag} POST /disconnect userId=${userId}`);

    const success = await disconnect(userId, toolkitSlug, appType);
    res.json({ ok: success });
  });

  // OAuth callback — Composio redirects here after user authorizes.
  // This endpoint intentionally does NOT write to the database. Query parameters
  // are client-controlled and can be forged (e.g., an attacker could craft a
  // callback URL with another user's user_id). The macOS app polls
  // /api/apps/:appType/status, which queries Composio directly as the source of
  // truth, so the DB state is updated from a trusted source instead.
  router.get('/callback', async (req, res) => {
    const result = await consumeOAuthCallback({
      state: typeof req.query.state === 'string' ? req.query.state : '',
      appType,
    });
    if (!result.ok) {
      res.status(400).send('<html><body>Invalid or expired connection link. Return to Perch and start again.</body></html>');
      return;
    }
    console.log(`${tag} OAuth callback accepted for attempt=${result.attemptId}`);

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
