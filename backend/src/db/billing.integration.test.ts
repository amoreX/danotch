import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import { Client } from 'pg';
import { test } from 'node:test';
import { databaseUrl, withClient } from './test-db.ts';

function client() {
  return new Client({
    connectionString: databaseUrl,
    ssl: databaseUrl?.includes('localhost') ? false : { rejectUnauthorized: false },
  });
}

test('checkout reservation, exact attachment, payment, and reversal are concurrency-safe', {
  skip: !databaseUrl,
}, async () => {
  const userId = randomUUID();
  const productId = `prod_${randomUUID()}`;
  await withClient(async (db) => {
    await db.query('insert into auth.users(id) values ($1)', [userId]);
    await db.query(
      `insert into public.danotch_user_profiles(
         id, email, full_name, trial_started_at, trial_ends_at, billing_status
       ) values ($1, $2, 'Billing Test', now() - interval '30 days',
         now() - interval '1 day', 'expired')`,
      [userId, `${userId}@example.test`],
    );
  });

  const first = client();
  const second = client();
  await first.connect();
  await second.connect();
  try {
    await first.query('set role danotch_webhook');
    await second.query('set role danotch_webhook');
    const reserveSql = `select public.danotch_reserve_checkout(
      $1, $2, 500, 'USD', 1, 'test_mode'
    ) as checkout`;
    const [a, b] = await Promise.all([
      first.query(reserveSql, [userId, productId]),
      second.query(reserveSql, [userId, productId]),
    ]);
    assert.equal(a.rows[0].checkout.id, b.rows[0].checkout.id);
    assert.equal(a.rows[0].checkout.idempotency_key, b.rows[0].checkout.idempotency_key);
    const checkout = a.rows[0].checkout as { id: string; idempotency_key: string };

    const wrongAttach = await first.query(
      `select public.danotch_attach_checkout_session($1, $2, $3, $4) as attached`,
      [checkout.id, 'checkout:wrong', 'cks_exact', 'https://checkout.example/cks_exact'],
    );
    assert.equal(wrongAttach.rows[0].attached, false);
    const attached = await first.query(
      `select public.danotch_attach_checkout_session($1, $2, $3, $4) as attached`,
      [checkout.id, checkout.idempotency_key, 'cks_exact', 'https://checkout.example/cks_exact'],
    );
    assert.equal(attached.rows[0].attached, true);

    const paymentId = `pay_${randomUUID()}`;
    const paymentSql = `select public.danotch_record_payment(
      $1, $2, $3, 'cus_1', 'payment.succeeded', 500, 'USD', $4,
      1, $5, 'cks_exact', 'test_mode'
    ) as outcome`;
    const [paymentA, paymentB] = await Promise.all([
      first.query(paymentSql, ['delivery-a', paymentId, userId, productId, checkout.id]),
      second.query(paymentSql, ['delivery-b', paymentId, userId, productId, checkout.id]),
    ]);
    assert.deepEqual(
      [paymentA.rows[0].outcome, paymentB.rows[0].outcome].sort(),
      ['duplicate', 'granted'],
    );

    const refundId = `ref_${randomUUID()}`;
    const reversalSql = `select public.danotch_record_payment_reversal(
      $1, 'refund.succeeded', $2, $3, 500, 'USD', true, 'customer request'
    ) as outcome`;
    const [refundA, refundB] = await Promise.all([
      first.query(reversalSql, ['delivery-refund-a', refundId, paymentId]),
      second.query(reversalSql, ['delivery-refund-b', refundId, paymentId]),
    ]);
    assert.deepEqual(
      [refundA.rows[0].outcome, refundB.rows[0].outcome].sort(),
      ['duplicate', 'revoked'],
    );

    await first.query('reset role');
    const profile = await first.query(
      `select billing_status, plan, lifetime_purchased_at, lifetime_revoked_at,
              dodo_payment_id
       from public.danotch_user_profiles where id = $1`,
      [userId],
    );
    assert.equal(profile.rows[0].billing_status, 'revoked');
    assert.equal(profile.rows[0].plan, 'free');
    assert.ok(profile.rows[0].lifetime_purchased_at);
    assert.ok(profile.rows[0].lifetime_revoked_at);
    assert.equal(profile.rows[0].dodo_payment_id, paymentId);
  } finally {
    await first.end();
    await second.end();
    await withClient(async (db) => {
      await db.query('delete from auth.users where id = $1', [userId]);
    });
  }
});
