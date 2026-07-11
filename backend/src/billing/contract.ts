import { config } from '../config.js';

export type WebhookPayload = {
  type?: string;
  data?: {
    payment_id?: string;
    total_amount?: number;
    currency?: string;
    metadata?: Record<string, unknown>;
    customer?: { customer_id?: string };
    product_cart?: Array<{ product_id?: string; quantity?: number }> | null;
  };
};

export type ContractResult =
  | {
      ok: true;
      paymentId: string;
      userId: string;
      customerId: string | null;
      amount: number;
      currency: string;
      productId: string;
    }
  | { ok: false; reason: string };

/**
 * Verify the server-controlled commercial contract on a verified payment event:
 * required identifiers plus exact product, quantity, amount, and currency. The
 * configured product/amount/currency come from server env, never the payload.
 */
export function validatePaymentContract(payload: WebhookPayload): ContractResult {
  const data = payload.data ?? {};
  const paymentId = data.payment_id;
  const userId = data.metadata?.user_id;

  if (!paymentId || typeof paymentId !== 'string') return { ok: false, reason: 'missing payment_id' };
  if (!userId || typeof userId !== 'string') return { ok: false, reason: 'missing metadata.user_id' };

  const cart = data.product_cart;
  if (!Array.isArray(cart) || cart.length === 0) {
    return { ok: false, reason: 'missing product_cart' };
  }

  const line = cart.find((item) => item?.product_id === config.dodo.productId);
  if (!line) {
    return { ok: false, reason: `product_cart does not contain configured product ${config.dodo.productId}` };
  }
  if (cart.length !== 1) {
    return { ok: false, reason: 'product_cart contains unexpected additional items' };
  }
  if ((line.quantity ?? 1) !== config.dodo.expectedQuantity) {
    return { ok: false, reason: 'unexpected quantity' };
  }

  const amount = data.total_amount;
  if (typeof amount !== 'number' || amount !== config.dodo.expectedAmount) {
    return { ok: false, reason: `amount ${amount} != expected ${config.dodo.expectedAmount}` };
  }

  const currency = (data.currency ?? '').toUpperCase();
  if (currency !== config.dodo.expectedCurrency) {
    return { ok: false, reason: `currency ${currency} != expected ${config.dodo.expectedCurrency}` };
  }

  return {
    ok: true,
    paymentId,
    userId,
    customerId: data.customer?.customer_id ?? null,
    amount,
    currency,
    productId: config.dodo.productId,
  };
}
