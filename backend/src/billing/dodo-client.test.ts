import assert from 'node:assert/strict';
import { test } from 'node:test';

process.env.DODO_PAYMENTS_PRODUCT_ID = 'prod_perch_lifetime';
process.env.DODO_PAYMENTS_RETURN_URL = 'http://localhost:3001/api/billing/return';
process.env.DODO_PAYMENTS_EXPECTED_QUANTITY = '1';

const { createDodoCheckout } = await import('./dodo-client.ts');

test('Dodo checkout sends stable idempotency through typed options and explicit header', async () => {
  let body: unknown;
  let options: unknown;
  const fakeClient = {
    checkoutSessions: {
      create: async (request: unknown, requestOptions: unknown) => {
        body = request;
        options = requestOptions;
        return {
          session_id: 'cks_123',
          checkout_url: 'https://checkout.dodopayments.com/cks_123',
        };
      },
    },
  };

  await createDodoCheckout({
    userId: 'user-123',
    email: 'buyer@example.test',
    checkoutRecordId: 'record-123',
    idempotencyKey: 'checkout:stable-123',
  }, fakeClient as never);

  assert.deepEqual((body as { metadata: Record<string, string> }).metadata, {
    user_id: 'user-123',
    checkout_record_id: 'record-123',
  });
  assert.equal((options as { idempotencyKey: string }).idempotencyKey, 'checkout:stable-123');
  assert.equal(
    (options as { headers: Record<string, string> }).headers['Idempotency-Key'],
    'checkout:stable-123',
  );
});
