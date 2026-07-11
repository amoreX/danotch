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
      metadata: { user_id: 'user-abc' },
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
