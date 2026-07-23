import assert from 'node:assert/strict';
import { createServer } from 'node:http';
import { afterEach, test } from 'node:test';
import express, { type RequestHandler } from 'express';

process.env.DODO_PAYMENTS_PRODUCT_ID = 'prod_perch_lifetime';
process.env.DODO_PAYMENTS_EXPECTED_AMOUNT = '500';
process.env.DODO_PAYMENTS_EXPECTED_CURRENCY = 'USD';
process.env.DODO_PAYMENTS_EXPECTED_QUANTITY = '1';
process.env.DODO_PAYMENTS_ENVIRONMENT = 'test_mode';
process.env.SUPABASE_URL = 'https://example.supabase.co';
process.env.SUPABASE_PUBLISHABLE_KEY = 'test-publishable-key';

const { createBillingRoutes } = await import('./billing.ts');

const servers: Array<ReturnType<typeof createServer>> = [];
afterEach(async () => {
  await Promise.all(servers.splice(0).map(
    (server) => new Promise<void>((resolve) => server.close(() => resolve())),
  ));
});

const auth: RequestHandler = (req, _res, next) => {
  req.user = {
    sub: '11111111-1111-4111-8111-111111111111',
    email: 'buyer@example.test',
    role: 'authenticated',
    authTime: Date.now(),
  };
  next();
};

const expiredStatus = {
  userId: '11111111-1111-4111-8111-111111111111',
  billingStatus: 'expired' as const,
  trialStartedAt: '2026-01-01T00:00:00.000Z',
  trialEndsAt: '2026-01-15T00:00:00.000Z',
  trialDaysRemaining: 0,
  lifetimePurchasedAt: null,
  hasActiveProvider: false,
  activeProvider: null,
  canUseServerKey: false,
  requiresPurchase: true,
  requiresProviderKey: false,
};

const reservation = {
  id: '22222222-2222-4222-8222-222222222222',
  idempotencyKey: 'checkout:stable-key',
  dodoSessionId: null,
  checkoutUrl: null,
  expiresAt: '2026-07-24T00:30:00.000Z',
};

function defaults() {
  return {
    requireAuth: auth,
    getBillingStatus: async () => expiredStatus,
    reserveCheckout: async () => reservation,
    attachCheckoutSession: async () => true,
    createDodoCheckout: async () => ({
      session_id: 'cks_123',
      checkout_url: 'https://checkout.dodopayments.com/cks_123',
    }),
    recordPayment: async () => 'granted' as const,
    recordPaymentReversal: async () => 'revoked' as const,
    checkoutConfigured: () => true,
    webhookConfigured: () => true,
    unwrapWebhook: () => ({ type: 'ignored' }),
  };
}

async function fixture(overrides: Record<string, unknown> = {}) {
  const app = express();
  app.use('/api/billing/webhook', express.raw({ type: '*/*' }));
  app.use(express.json());
  app.use('/api/billing', createBillingRoutes({ ...defaults(), ...overrides } as never));
  const server = createServer(app);
  servers.push(server);
  await new Promise<void>((resolve) => server.listen(0, '127.0.0.1', resolve));
  const address = server.address();
  assert(address && typeof address !== 'string');
  return `http://127.0.0.1:${address.port}`;
}

test('checkout reuses the one attached active checkout without another Dodo call', async () => {
  let createCalls = 0;
  const baseUrl = await fixture({
    reserveCheckout: async () => ({
      ...reservation,
      dodoSessionId: 'cks_existing',
      checkoutUrl: 'https://checkout.dodopayments.com/cks_existing',
    }),
    createDodoCheckout: async () => {
      createCalls += 1;
      throw new Error('must not create');
    },
  });
  const response = await fetch(`${baseUrl}/api/billing/checkout`, { method: 'POST' });
  assert.equal(response.status, 200);
  assert.deepEqual(await response.json(), {
    checkout_url: 'https://checkout.dodopayments.com/cks_existing',
    reused: true,
  });
  assert.equal(createCalls, 0);
});

test('checkout remains available while the account is actively trialing', async () => {
  const baseUrl = await fixture({
    getBillingStatus: async () => ({
      ...expiredStatus,
      billingStatus: 'trialing',
      trialDaysRemaining: 12,
      canUseServerKey: true,
      requiresPurchase: false,
    }),
  });
  const response = await fetch(`${baseUrl}/api/billing/checkout`, { method: 'POST' });
  assert.equal(response.status, 200);
  assert.deepEqual(await response.json(), {
    checkout_url: 'https://checkout.dodopayments.com/cks_123',
    reused: false,
  });
});

test('billing return page offers only the fixed Perch completion deep link', async () => {
  const baseUrl = await fixture();
  const response = await fetch(`${baseUrl}/api/billing/return?payment_id=untrusted`);
  const body = await response.text();
  assert.equal(response.status, 200);
  assert.match(response.headers.get('content-security-policy') ?? '', /default-src 'none'/);
  assert.match(body, /href="perch:\/\/billing\/complete"/);
  assert.doesNotMatch(body, /untrusted/);
});

test('checkout passes the stable reservation idempotency key and attaches exact session', async () => {
  let createInput: unknown;
  let attachInput: unknown;
  const baseUrl = await fixture({
    createDodoCheckout: async (input: unknown) => {
      createInput = input;
      return {
        session_id: 'cks_new',
        checkout_url: 'https://checkout.dodopayments.com/cks_new',
      };
    },
    attachCheckoutSession: async (input: unknown) => {
      attachInput = input;
      return true;
    },
  });
  const response = await fetch(`${baseUrl}/api/billing/checkout`, { method: 'POST' });
  assert.equal(response.status, 200);
  assert.equal((createInput as { idempotencyKey: string }).idempotencyKey, 'checkout:stable-key');
  assert.deepEqual(attachInput, {
    recordId: reservation.id,
    idempotencyKey: reservation.idempotencyKey,
    dodoSessionId: 'cks_new',
    checkoutUrl: 'https://checkout.dodopayments.com/cks_new',
  });
});

test('checkout fails closed when Dodo session attachment is rejected', async () => {
  const baseUrl = await fixture({ attachCheckoutSession: async () => false });
  const response = await fetch(`${baseUrl}/api/billing/checkout`, { method: 'POST' });
  assert.equal(response.status, 502);
  assert.equal((await response.json() as { code: string }).code, 'checkout_failed');
});

test('verified payment route forwards exact checkout bindings to the atomic RPC', async () => {
  let recorded: unknown;
  const payload = {
    type: 'payment.succeeded',
    data: {
      payment_id: 'pay_123',
      total_amount: 500,
      currency: 'usd',
      checkout_session_id: 'cks_123',
      metadata: {
        user_id: '11111111-1111-4111-8111-111111111111',
        checkout_record_id: reservation.id,
      },
      customer: { customer_id: 'cus_123' },
      product_cart: [{ product_id: 'prod_perch_lifetime', quantity: 1 }],
    },
  };
  const baseUrl = await fixture({
    unwrapWebhook: () => payload,
    recordPayment: async (input: unknown) => {
      recorded = input;
      return 'granted';
    },
  });
  const response = await fetch(`${baseUrl}/api/billing/webhook`, {
    method: 'POST',
    headers: {
      'content-type': 'application/json',
      'webhook-id': 'delivery-1',
      'webhook-signature': 'verified-by-fixture',
      'webhook-timestamp': '1',
    },
    body: JSON.stringify(payload),
  });
  assert.equal(response.status, 200);
  assert.equal((recorded as { checkoutRecordId: string }).checkoutRecordId, reservation.id);
  assert.equal((recorded as { dodoSessionId: string }).dodoSessionId, 'cks_123');
});

test('verified full refund is routed to the atomic revocation RPC', async () => {
  let reversal: unknown;
  const payload = {
    type: 'refund.succeeded',
    data: {
      refund_id: 'ref_123',
      payment_id: 'pay_123',
      is_partial: false,
      amount: 500,
      currency: 'usd',
      reason: 'customer request',
    },
  };
  const baseUrl = await fixture({
    unwrapWebhook: () => payload,
    recordPaymentReversal: async (input: unknown) => {
      reversal = input;
      return 'revoked';
    },
  });
  const response = await fetch(`${baseUrl}/api/billing/webhook`, {
    method: 'POST',
    headers: {
      'content-type': 'application/json',
      'webhook-id': 'delivery-refund',
      'webhook-signature': 'verified-by-fixture',
      'webhook-timestamp': '1',
    },
    body: JSON.stringify(payload),
  });
  assert.equal(response.status, 200);
  assert.equal((reversal as { providerEventId: string }).providerEventId, 'ref_123');
  assert.equal((await response.json() as { outcome: string }).outcome, 'revoked');
});
