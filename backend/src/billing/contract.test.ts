import { test } from 'node:test';
import assert from 'node:assert/strict';

// The contract validator reads config at call time. Set env before importing.
process.env.DODO_PAYMENTS_PRODUCT_ID = 'prod_perch_lifetime';
process.env.DODO_PAYMENTS_EXPECTED_AMOUNT = '500';
process.env.DODO_PAYMENTS_EXPECTED_CURRENCY = 'USD';
process.env.DODO_PAYMENTS_EXPECTED_QUANTITY = '1';

const { validatePaymentContract } = await import('./contract.ts');

function validPayload() {
  return {
    type: 'payment.succeeded',
    data: {
      payment_id: 'pay_123',
      total_amount: 500,
      currency: 'usd',
      metadata: {
        user_id: 'user-abc',
        checkout_record_id: 'b148a55f-d2bf-4f8c-8994-78a950969a5d',
      },
      checkout_session_id: 'cks_123',
      customer: { customer_id: 'cus_1' },
      product_cart: [{ product_id: 'prod_perch_lifetime', quantity: 1 }],
    },
  };
}

test('accepts a payment matching the configured contract', () => {
  const result = validatePaymentContract(validPayload());
  assert.equal(result.ok, true);
  if (result.ok) {
    assert.equal(result.paymentId, 'pay_123');
    assert.equal(result.userId, 'user-abc');
    assert.equal(result.amount, 500);
    assert.equal(result.currency, 'USD');
    assert.equal(result.checkoutRecordId, 'b148a55f-d2bf-4f8c-8994-78a950969a5d');
    assert.equal(result.dodoSessionId, 'cks_123');
  }
});

test('rejects missing payment_id', () => {
  const p = validPayload();
  delete (p.data as { payment_id?: string }).payment_id;
  assert.equal(validatePaymentContract(p).ok, false);
});

test('rejects missing metadata.user_id', () => {
  const p = validPayload();
  p.data.metadata = {};
  assert.equal(validatePaymentContract(p).ok, false);
});

test('rejects payment without exact internal checkout and Dodo session bindings', () => {
  const missingRecord = validPayload();
  delete missingRecord.data.metadata.checkout_record_id;
  assert.equal(validatePaymentContract(missingRecord).ok, false);

  const missingSession = validPayload();
  delete (missingSession.data as { checkout_session_id?: string }).checkout_session_id;
  assert.equal(validatePaymentContract(missingSession).ok, false);
});

test('rejects a missing product cart (fails closed)', () => {
  const p = validPayload();
  p.data.product_cart = null;
  assert.equal(validatePaymentContract(p).ok, false);
});

test('rejects the wrong product', () => {
  const p = validPayload();
  p.data.product_cart = [{ product_id: 'prod_other', quantity: 1 }];
  assert.equal(validatePaymentContract(p).ok, false);
});

test('rejects a discounted / zero amount', () => {
  const p = validPayload();
  p.data.total_amount = 0;
  assert.equal(validatePaymentContract(p).ok, false);
});

test('rejects a mismatched currency', () => {
  const p = validPayload();
  p.data.currency = 'eur';
  assert.equal(validatePaymentContract(p).ok, false);
});

test('rejects extra cart items', () => {
  const p = validPayload();
  p.data.product_cart = [
    { product_id: 'prod_perch_lifetime', quantity: 1 },
    { product_id: 'prod_extra', quantity: 1 },
  ];
  assert.equal(validatePaymentContract(p).ok, false);
});

test('accepts terminal full-refund and lost-dispute reversal contracts', async () => {
  const { validatePaymentReversal } = await import('./contract.ts');
  const refund = validatePaymentReversal({
    type: 'refund.succeeded',
    data: {
      refund_id: 'ref_1',
      payment_id: 'pay_123',
      is_partial: false,
      amount: 500,
      currency: 'usd',
      reason: 'requested',
    },
  });
  assert.equal(refund.ok, true);
  assert.equal(validatePaymentReversal({
    type: 'refund.succeeded',
    data: {
      refund_id: 'ref_without_optional_amount',
      payment_id: 'pay_123',
      is_partial: false,
    },
  }).ok, true);

  const dispute = validatePaymentReversal({
    type: 'dispute.lost',
    data: { dispute_id: 'dsp_1', payment_id: 'pay_123', currency: 'usd' },
  });
  assert.equal(dispute.ok, true);
});

test('fails closed for partial refunds and non-terminal disputes', async () => {
  const { validatePaymentReversal } = await import('./contract.ts');
  assert.equal(validatePaymentReversal({
    type: 'refund.succeeded',
    data: {
      refund_id: 'ref_partial',
      payment_id: 'pay_123',
      is_partial: true,
      amount: 100,
      currency: 'USD',
    },
  }).ok, false);
  assert.equal(validatePaymentReversal({
    type: 'dispute.opened',
    data: { dispute_id: 'dsp_open', payment_id: 'pay_123' },
  }).ok, false);
});
