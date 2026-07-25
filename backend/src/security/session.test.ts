import assert from 'node:assert/strict';
import { randomBytes } from 'node:crypto';
import { test } from 'node:test';
import { SessionManager } from './session.ts';

test('installation secret is exchanged for an opaque short-lived token', () => {
  const secret = randomBytes(32);
  const encoded = secret.toString('base64');
  const sessions = new SessionManager(Buffer.from(secret), 60_000);
  try {
    assert.equal(sessions.exchange(randomBytes(32).toString('base64')), undefined);
    const exchanged = sessions.exchange(encoded);
    assert.ok(exchanged);
    assert.notEqual(exchanged.token, encoded);
    assert.equal(sessions.authenticate(exchanged.token), true);
    assert.equal(sessions.authenticate(`${exchanged.token}x`), false);
  } finally {
    sessions.close();
  }
});
