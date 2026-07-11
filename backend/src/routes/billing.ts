import { Router } from 'express';
import { requireAuth } from '../middleware/auth.js';
import {
  getBillingStatus,
  recordPayment,
  createCheckoutRecord,
  attachCheckoutSession,
  EntitlementError,
} from '../billing/entitlements.js';
import { config } from '../config.js';
import { getDodoClient, isCheckoutConfigured, isWebhookConfigured } from '../billing/dodo-client.js';
import { validatePaymentContract, type WebhookPayload } from '../billing/contract.js';

export function createBillingRoutes(): Router {
  const router = Router();

  router.get('/status', requireAuth, async (req, res) => {
    try {
      const status = await getBillingStatus(req.user!.sub);
      res.json(status);
    } catch (err) {
      // Distinguish a genuinely missing profile (client should re-auth) from a
      // transient operational failure (client must NOT log out).
      if (err instanceof EntitlementError && err.code === 'profile_not_found') {
        res.status(404).json({ error: err.message, code: 'profile_not_found' });
        return;
      }
      const message = err instanceof Error ? err.message : 'Failed to load billing status';
      res.status(503).json({ error: message, code: 'billing_unavailable' });
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

      // Create a server-owned checkout record first so the webhook can bind the
      // eventual payment to this authenticated user and expected commercial terms.
      const recordId = await createCheckoutRecord(req.user!.sub, {
        productId: config.dodo.productId,
        expectedAmount: config.dodo.expectedAmount,
        expectedCurrency: config.dodo.expectedCurrency,
        expectedQuantity: config.dodo.expectedQuantity,
        environment: config.dodo.environment,
      });

      const client = getDodoClient();
      const session = await client.checkoutSessions.create({
        product_cart: [{ product_id: config.dodo.productId, quantity: config.dodo.expectedQuantity }],
        customer: { email: req.user!.email },
        return_url: config.dodo.returnUrl,
        metadata: { user_id: req.user!.sub, checkout_record_id: recordId },
      });

      const sessionId = (session as { session_id?: string; id?: string }).session_id
        ?? (session as { id?: string }).id;
      if (sessionId) {
        await attachCheckoutSession(recordId, sessionId);
      }

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
    let payload: WebhookPayload;
    try {
      const rawBody = Buffer.isBuffer(req.body) ? req.body.toString('utf8') : String(req.body);
      payload = client.webhooks.unwrap(rawBody, {
        headers: {
          'webhook-id': req.headers['webhook-id'] as string,
          'webhook-signature': req.headers['webhook-signature'] as string,
          'webhook-timestamp': req.headers['webhook-timestamp'] as string,
        },
      }) as WebhookPayload;
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

    const contract = validatePaymentContract(payload);
    if (!contract.ok) {
      // Verified but does not match the configured commercial contract. This is a
      // terminal decision (retrying won't change it), so acknowledge with 200
      // WITHOUT granting anything.
      console.warn(`[billing] payment.succeeded rejected: ${contract.reason}`);
      res.json({ received: true });
      return;
    }

    try {
      const outcome = await recordPayment({
        deliveryId: (req.headers['webhook-id'] as string) ?? null,
        paymentId: contract.paymentId,
        claimedUserId: contract.userId,
        dodoCustomerId: contract.customerId,
        eventType: payload.type,
        amount: contract.amount,
        currency: contract.currency,
        productId: contract.productId,
      });
      console.log(`[billing] payment ${contract.paymentId} → ${outcome} (user ${contract.userId}).`);
      // granted / duplicate / unknown_profile / rejected are all terminal.
      res.json({ received: true, outcome });
    } catch (err) {
      // Operational/database failure. Return non-2xx so Dodo retries with backoff.
      console.error(
        `[billing] recordPayment failed for user_id=${contract.userId} payment_id=${contract.paymentId}:`,
        err instanceof Error ? err.message : err,
      );
      res.status(503).json({ error: 'Temporary failure recording payment; please retry.' });
    }
  });

  return router;
}
