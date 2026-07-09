import { Router } from 'express';
import { requireAuth } from '../middleware/auth.js';
import { getBillingStatus, markUserPaid } from '../billing/entitlements.js';
import { config } from '../config.js';
import { getDodoClient, isCheckoutConfigured, isWebhookConfigured } from '../billing/dodo-client.js';

export function createBillingRoutes(): Router {
  const router = Router();

  router.get('/status', requireAuth, async (req, res) => {
    try {
      const status = await getBillingStatus(req.user!.sub);
      res.json(status);
    } catch (err) {
      const message = err instanceof Error ? err.message : 'Failed to load billing status';
      res.status(404).json({ error: message });
    }
  });

  router.post('/checkout', requireAuth, async (req, res) => {
    try {
      const status = await getBillingStatus(req.user!.sub);
      if (status.billingStatus === 'paid') {
        res.json({ checkout_url: null, error: 'Already purchased — nothing to check out.' });
        return;
      }

      if (!isCheckoutConfigured()) {
        res.status(503).json({
          error: 'Checkout is not configured yet.',
          code: 'checkout_not_configured',
        });
        return;
      }

      const client = getDodoClient();
      const session = await client.checkoutSessions.create({
        product_cart: [{ product_id: config.dodo.productId, quantity: 1 }],
        customer: { email: req.user!.email },
        return_url: config.dodo.returnUrl,
        metadata: { user_id: req.user!.sub },
      });

      res.json({ checkout_url: session.checkout_url });
    } catch (err) {
      console.error('[billing] checkout session creation failed:', err);
      res.status(502).json({
        error: 'Failed to create checkout session.',
        code: 'checkout_failed',
      });
    }
  });

  // Cosmetic only — the webhook is the sole source of truth for entitlement writes.
  // Query params here (payment_id, status, etc.) are client-controlled and unverified.
  router.get('/return', (_req, res) => {
    res.send(`
      <html>
        <body style="background:#000;color:#fff;font-family:system-ui;display:flex;align-items:center;justify-content:center;height:100vh;margin:0">
          <div style="text-align:center">
            <h1 style="font-size:48px;margin:0">✓</h1>
            <p style="color:#4A9E5C;font-size:18px;margin-top:12px">Thanks for your purchase</p>
            <p style="color:#666;font-size:14px;margin-top:8px">You can close this tab and return to Perch</p>
          </div>
        </body>
      </html>
    `);
  });

  // No requireAuth — Dodo is the caller, not a logged-in user. index.ts mounts
  // express.raw() for this path ahead of the global express.json() so the
  // exact raw bytes are available for signature verification.
  router.post('/webhook', async (req, res) => {
    if (!isWebhookConfigured()) {
      res.status(503).json({ error: 'Webhook is not configured.', code: 'webhook_not_configured' });
      return;
    }

    const client = getDodoClient();
    let payload: any;
    try {
      const rawBody = Buffer.isBuffer(req.body) ? req.body.toString('utf8') : String(req.body);
      payload = client.webhooks.unwrap(rawBody, {
        headers: {
          'webhook-id': req.headers['webhook-id'] as string,
          'webhook-signature': req.headers['webhook-signature'] as string,
          'webhook-timestamp': req.headers['webhook-timestamp'] as string,
        },
      });
    } catch (err) {
      console.warn('[billing] webhook signature verification failed:', err instanceof Error ? err.message : err);
      res.status(401).json({ error: 'Invalid signature' });
      return;
    }

    if (payload?.type !== 'payment.succeeded') {
      console.log(`[billing] webhook event "${payload?.type}" acknowledged (no-op).`);
      res.json({ received: true });
      return;
    }

    const userId = payload.data?.metadata?.user_id;
    const paymentId = payload.data?.payment_id;
    const customerId = payload.data?.customer?.customer_id ?? null;

    if (!userId || !paymentId) {
      console.warn('[billing] payment.succeeded missing metadata.user_id or payment_id — acknowledging without a DB write.');
      res.json({ received: true });
      return;
    }

    try {
      const result = await markUserPaid(userId, { dodoCustomerId: customerId, dodoPaymentId: paymentId });
      if (result.alreadyProcessed) {
        console.log(`[billing] payment ${paymentId} already processed for user ${userId} — skipping duplicate write.`);
      } else {
        console.log(`[billing] user ${userId} marked paid (payment ${paymentId}).`);
      }
    } catch (err) {
      // Unmatched/unknown user_id (or any other write failure): log for manual
      // reconciliation and still ack 200 — retrying won't resolve an unknown
      // user, so this avoids an infinite Dodo retry loop.
      console.error(
        `[billing] markUserPaid failed for user_id=${userId} payment_id=${paymentId}:`,
        err instanceof Error ? err.message : err,
      );
    }

    res.json({ received: true });
  });

  return router;
}
