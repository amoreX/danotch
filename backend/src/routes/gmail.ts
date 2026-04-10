import { Router } from 'express';
import { requireAuth } from '../middleware/auth.js';
import {
  isComposioConfigured,
  getGmailConnectionStatus,
  initiateGmailConnection,
  disconnectGmail,
} from '../tools/gmail.js';

export function createGmailRoutes(): Router {
  const router = Router();

  // Check if Composio is configured at all
  router.get('/configured', (_req, res) => {
    res.json({ configured: isComposioConfigured() });
  });

  // Check Gmail connection status for the current user
  router.get('/status', requireAuth, async (req, res) => {
    const userId = req.user!.sub;
    console.log(`[gmail] GET /status userId=${userId}`);

    if (!isComposioConfigured()) {
      res.json({ connected: false, reason: 'composio_not_configured' });
      return;
    }

    const status = await getGmailConnectionStatus(userId);
    console.log(`[gmail] → connected=${status.connected}`);
    res.json(status);
  });

  // Initiate Gmail OAuth connection
  router.post('/connect', requireAuth, async (req, res) => {
    const userId = req.user!.sub;
    console.log(`[gmail] POST /connect userId=${userId}`);

    if (!isComposioConfigured()) {
      res.status(400).json({ error: 'Composio not configured' });
      return;
    }

    // Check if already connected
    const existing = await getGmailConnectionStatus(userId);
    if (existing.connected) {
      res.json({ already_connected: true });
      return;
    }

    const result = await initiateGmailConnection(userId);
    if (result.error) {
      res.status(400).json({ error: result.error });
      return;
    }

    console.log(`[gmail] → redirectUrl=${result.redirectUrl ? 'yes' : 'auto-connected'}`);
    res.json({ redirectUrl: result.redirectUrl, connected: !result.redirectUrl });
  });

  // Disconnect Gmail
  router.post('/disconnect', requireAuth, async (req, res) => {
    const userId = req.user!.sub;
    console.log(`[gmail] POST /disconnect userId=${userId}`);

    const success = await disconnectGmail(userId);
    res.json({ ok: success });
  });

  // OAuth callback — Composio redirects here after user authorizes
  router.get('/callback', (req, res) => {
    console.log('[gmail] OAuth callback received:', req.query);
    // Close the browser tab / show success page
    res.send(`
      <html>
        <body style="background:#000;color:#fff;font-family:system-ui;display:flex;align-items:center;justify-content:center;height:100vh;margin:0">
          <div style="text-align:center">
            <h1 style="font-size:48px;margin:0">✓</h1>
            <p style="color:#4A9E5C;font-size:18px;margin-top:12px">Gmail connected successfully</p>
            <p style="color:#666;font-size:14px;margin-top:8px">You can close this tab and return to Danotch</p>
          </div>
        </body>
      </html>
    `);
  });

  return router;
}
