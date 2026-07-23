import { Router, type RequestHandler } from 'express';
import { requireAuth } from '../middleware/auth.js';
import {
  getBillingStatus,
  recordPayment,
  recordPaymentReversal,
  reserveCheckout,
  attachCheckoutSession,
  EntitlementError,
} from '../billing/entitlements.js';
import { config } from '../config.js';
import {
  createDodoCheckout,
  getDodoClient,
  isCheckoutConfigured,
  isWebhookConfigured,
} from '../billing/dodo-client.js';
import {
  validatePaymentContract,
  validatePaymentReversal,
  type WebhookPayload,
} from '../billing/contract.js';

type BillingRouteDependencies = {
  requireAuth: RequestHandler;
  getBillingStatus: typeof getBillingStatus;
  reserveCheckout: typeof reserveCheckout;
  attachCheckoutSession: typeof attachCheckoutSession;
  createDodoCheckout: typeof createDodoCheckout;
  recordPayment: typeof recordPayment;
  recordPaymentReversal: typeof recordPaymentReversal;
  checkoutConfigured: () => boolean;
  webhookConfigured: () => boolean;
  unwrapWebhook: (rawBody: string, headers: Record<string, string>) => WebhookPayload;
};

export function createBillingRoutes(
  overrides: Partial<BillingRouteDependencies> = {},
): Router {
  const dependencies: BillingRouteDependencies = {
    requireAuth,
    getBillingStatus,
    reserveCheckout,
    attachCheckoutSession,
    createDodoCheckout,
    recordPayment,
    recordPaymentReversal,
    checkoutConfigured: isCheckoutConfigured,
    webhookConfigured: isWebhookConfigured,
    unwrapWebhook: (rawBody, headers) =>
      getDodoClient().webhooks.unwrap(rawBody, { headers }) as WebhookPayload,
    ...overrides,
  };
  const router = Router();

  router.get('/status', dependencies.requireAuth, async (req, res) => {
    try {
      const status = await dependencies.getBillingStatus(req.user!.sub);
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

  router.post('/checkout', dependencies.requireAuth, async (req, res) => {
    try {
      const status = await dependencies.getBillingStatus(req.user!.sub);
      if (status.billingStatus === 'paid') {
        res.status(409).json({
          error: 'Already purchased — nothing to check out.',
          code: 'already_purchased',
        });
        return;
      }

      if (!dependencies.checkoutConfigured()) {
        res.status(503).json({
          error: 'Checkout is not configured yet.',
          code: 'checkout_not_configured',
        });
        return;
      }

      // Create a server-owned checkout record first so the webhook can bind the
      // eventual payment to this authenticated user and expected commercial terms.
      const reservation = await dependencies.reserveCheckout(req.user!.sub, {
        productId: config.dodo.productId,
        expectedAmount: config.dodo.expectedAmount,
        expectedCurrency: config.dodo.expectedCurrency,
        expectedQuantity: config.dodo.expectedQuantity,
        environment: config.dodo.environment,
      });

      if (reservation.checkoutUrl && reservation.dodoSessionId) {
        res.json({ checkout_url: reservation.checkoutUrl, reused: true });
        return;
      }

      const session = await dependencies.createDodoCheckout({
        userId: req.user!.sub,
        email: req.user!.email,
        checkoutRecordId: reservation.id,
        idempotencyKey: reservation.idempotencyKey,
      });

      if (
        typeof session.session_id !== 'string'
        || !session.session_id
        || typeof session.checkout_url !== 'string'
        || !session.checkout_url
      ) {
        throw new Error('Dodo returned an incomplete checkout session');
      }

      const attached = await dependencies.attachCheckoutSession({
        recordId: reservation.id,
        idempotencyKey: reservation.idempotencyKey,
        dodoSessionId: session.session_id,
        checkoutUrl: session.checkout_url,
      });
      if (!attached) {
        throw new Error('Checkout session could not be attached to its reservation');
      }

      res.json({ checkout_url: session.checkout_url, reused: false });
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
    res
      .set('Content-Security-Policy', "default-src 'none'; style-src 'unsafe-inline'; base-uri 'none'; form-action 'none'")
      .type('html')
      .send(`<!doctype html>
        <html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width">
        <title>Return to Perch</title></head>
        <body style="background:#000;color:#fff;font-family:system-ui;display:flex;align-items:center;justify-content:center;height:100vh;margin:0">
          <main style="text-align:center;max-width:420px;padding:24px">
            <h1 style="font-size:48px;margin:0">✓</h1>
            <p style="color:#4A9E5C;font-size:18px;margin-top:12px">Checkout complete</p>
            <p style="color:#999;font-size:14px;margin:8px 0 20px">Perch confirms access from the signed webhook. Return to the app to check this account.</p>
            <a href="perch://billing/complete" style="display:inline-block;background:#8B7CF6;color:#fff;text-decoration:none;padding:10px 16px;border-radius:10px">Return to Perch</a>
          </main>
        </body></html>`);
  });

  // No requireAuth — Dodo is the caller, not a logged-in user. index.ts mounts
  // express.raw() for this path ahead of the global express.json() so the
  // exact raw bytes are available for signature verification.
  router.post('/webhook', async (req, res) => {
    if (!dependencies.webhookConfigured()) {
      res.status(503).json({ error: 'Webhook is not configured.', code: 'webhook_not_configured' });
      return;
    }

    let payload: WebhookPayload;
    try {
      const rawBody = Buffer.isBuffer(req.body) ? req.body.toString('utf8') : String(req.body);
      payload = dependencies.unwrapWebhook(rawBody, {
        'webhook-id': req.headers['webhook-id'] as string,
        'webhook-signature': req.headers['webhook-signature'] as string,
        'webhook-timestamp': req.headers['webhook-timestamp'] as string,
      });
    } catch (err) {
      console.warn('[billing] webhook signature verification failed:', err instanceof Error ? err.message : err);
      res.status(401).json({ error: 'Invalid signature' });
      return;
    }

    if (
      payload?.type === 'refund.succeeded'
      || payload?.type === 'dispute.accepted'
      || payload?.type === 'dispute.lost'
    ) {
      const reversal = validatePaymentReversal(payload);
      if (!reversal.ok) {
        console.warn(`[billing] ${payload.type} rejected: ${reversal.reason}`);
        res.json({ received: true });
        return;
      }
      try {
        const outcome = await dependencies.recordPaymentReversal({
          deliveryId: (req.headers['webhook-id'] as string) ?? null,
          eventType: reversal.eventType,
          providerEventId: reversal.providerEventId,
          paymentId: reversal.paymentId,
          amount: reversal.amount,
          currency: reversal.currency,
          reason: reversal.reason,
        });
        res.json({ received: true, outcome });
      } catch (err) {
        console.error(`[billing] reversal failed for payment ${reversal.paymentId}:`, err);
        res.status(503).json({ error: 'Temporary failure recording reversal; please retry.' });
      }
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
      const outcome = await dependencies.recordPayment({
        deliveryId: (req.headers['webhook-id'] as string) ?? null,
        paymentId: contract.paymentId,
        claimedUserId: contract.userId,
        dodoCustomerId: contract.customerId,
        eventType: payload.type,
        amount: contract.amount,
        currency: contract.currency,
        productId: contract.productId,
        quantity: contract.quantity,
        checkoutRecordId: contract.checkoutRecordId,
        dodoSessionId: contract.dodoSessionId,
        environment: config.dodo.environment,
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
