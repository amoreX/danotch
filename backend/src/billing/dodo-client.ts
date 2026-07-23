import DodoPayments from 'dodopayments';
import type { CheckoutSessionResponse } from 'dodopayments/resources/checkout-sessions';
import { config } from '../config.js';

let client: DodoPayments | null = null;

export function isCheckoutConfigured(): boolean {
  return Boolean(config.dodo.apiKey && config.dodo.productId && config.dodo.returnUrl);
}

export function isWebhookConfigured(): boolean {
  return Boolean(config.dodo.webhookKey);
}

export function isDodoLiveReady(): boolean {
  return Boolean(
    config.dodo.environment === 'live_mode'
    && config.dodo.apiKey
    && config.dodo.webhookKey
    && config.dodo.productId
    && config.dodo.returnUrl.startsWith('https://')
    && config.dodo.expectedAmount > 0
    && config.dodo.expectedQuantity > 0
    && /^[A-Z]{3}$/.test(config.dodo.expectedCurrency),
  );
}

export async function createDodoCheckout(params: {
  userId: string;
  email: string;
  checkoutRecordId: string;
  idempotencyKey: string;
}, checkoutClient: Pick<DodoPayments, 'checkoutSessions'> = getDodoClient()): Promise<CheckoutSessionResponse> {
  return checkoutClient.checkoutSessions.create({
    product_cart: [{
      product_id: config.dodo.productId,
      quantity: config.dodo.expectedQuantity,
    }],
    customer: { email: params.email },
    return_url: config.dodo.returnUrl,
    metadata: {
      user_id: params.userId,
      checkout_record_id: params.checkoutRecordId,
    },
  }, {
    // dodopayments@2.40.1 exposes idempotencyKey in RequestOptions but does not
    // initialize its generated idempotencyHeader. Keep the typed option and the
    // explicit standard header until the SDK wires it internally.
    idempotencyKey: params.idempotencyKey,
    headers: { 'Idempotency-Key': params.idempotencyKey },
  });
}

/**
 * Lazily-constructed singleton client. Callers must check isCheckoutConfigured()
 * / isWebhookConfigured() before invoking checkout or webhook operations —
 * this helper does not itself gate on config presence.
 */
export function getDodoClient(): DodoPayments {
  if (!client) {
    client = new DodoPayments({
      bearerToken: config.dodo.apiKey,
      environment: config.dodo.environment === 'live_mode' ? 'live_mode' : 'test_mode',
      webhookKey: config.dodo.webhookKey,
    });
  }
  return client;
}
