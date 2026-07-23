import { config } from '../config.js';

export type WebhookPayload = {
  type?: string;
  data?: {
    payment_id?: string;
    refund_id?: string;
    dispute_id?: string;
    total_amount?: number;
    amount?: number | string | null;
    currency?: string;
    is_partial?: boolean;
    reason?: string | null;
    checkout_session_id?: string | null;
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
      quantity: number;
      checkoutRecordId: string;
      dodoSessionId: string;
    }
  | { ok: false; reason: string };

export type ReversalResult =
  | {
      ok: true;
      eventType: 'refund.succeeded' | 'dispute.accepted' | 'dispute.lost';
      providerEventId: string;
      paymentId: string;
      amount: number | null;
      currency: string | null;
      reason: string | null;
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
  const checkoutRecordId = data.metadata?.checkout_record_id;
  const dodoSessionId = data.checkout_session_id;

  if (!paymentId || typeof paymentId !== 'string') return { ok: false, reason: 'missing payment_id' };
  if (!userId || typeof userId !== 'string') return { ok: false, reason: 'missing metadata.user_id' };
  if (!checkoutRecordId || typeof checkoutRecordId !== 'string') {
    return { ok: false, reason: 'missing metadata.checkout_record_id' };
  }
  if (!/^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(checkoutRecordId)) {
    return { ok: false, reason: 'invalid metadata.checkout_record_id' };
  }
  if (!dodoSessionId || typeof dodoSessionId !== 'string') {
    return { ok: false, reason: 'missing checkout_session_id' };
  }

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
    quantity: line.quantity ?? 1,
    checkoutRecordId,
    dodoSessionId,
  };
}

export function validatePaymentReversal(payload: WebhookPayload): ReversalResult {
  const data = payload.data ?? {};
  const paymentId = data.payment_id;
  if (!paymentId || typeof paymentId !== 'string') {
    return { ok: false, reason: 'missing reversal payment_id' };
  }

  if (payload.type === 'refund.succeeded') {
    if (!data.refund_id || typeof data.refund_id !== 'string') {
      return { ok: false, reason: 'missing refund_id' };
    }
    if (data.is_partial !== false) {
      return { ok: false, reason: 'partial or unspecified refund does not revoke lifetime access' };
    }
    if (data.amount != null && (typeof data.amount !== 'number' || data.amount <= 0)) {
      return { ok: false, reason: 'invalid refund amount' };
    }
    const currency = typeof data.currency === 'string' ? data.currency.toUpperCase() : null;
    return {
      ok: true,
      eventType: payload.type,
      providerEventId: data.refund_id,
      paymentId,
      amount: typeof data.amount === 'number' ? data.amount : null,
      currency,
      reason: typeof data.reason === 'string' ? data.reason : null,
    };
  }

  if (payload.type === 'dispute.accepted' || payload.type === 'dispute.lost') {
    if (!data.dispute_id || typeof data.dispute_id !== 'string') {
      return { ok: false, reason: 'missing dispute_id' };
    }
    return {
      ok: true,
      eventType: payload.type,
      providerEventId: data.dispute_id,
      paymentId,
      amount: null,
      currency: typeof data.currency === 'string' ? data.currency.toUpperCase() : null,
      reason: typeof data.reason === 'string' ? data.reason : null,
    };
  }

  return { ok: false, reason: `unsupported reversal event ${payload.type ?? 'missing'}` };
}
