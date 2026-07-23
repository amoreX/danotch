import { test } from 'node:test';
import assert from 'node:assert/strict';
import { parseDeviceMessage, ProtocolSchemaError } from './schemas.ts';

const ID_A = '00000000-0000-4000-8000-00000000000a';
const ID_B = '00000000-0000-4000-8000-00000000000b';
const ID_C = '00000000-0000-4000-8000-00000000000c';

test('versioned device schemas accept exact valid messages', () => {
  assert.deepEqual(parseDeviceMessage({
    version: 1,
    type: 'event_ack',
    messageId: ID_A,
    deviceId: ID_B,
    eventId: ID_C,
    sequence: 1,
    fence: 0,
  }), {
    version: 1,
    type: 'event_ack',
    messageId: ID_A,
    deviceId: ID_B,
    eventId: ID_C,
    sequence: 1,
    fence: 0,
  });
});

test('schemas reject unsupported versions, unknown fields, and forged state', () => {
  const valid = {
    version: 1,
    type: 'cancel_run',
    messageId: ID_A,
    deviceId: ID_B,
    runId: ID_C,
    fence: 2,
  };
  assert.throws(
    () => parseDeviceMessage({ ...valid, version: 2 }),
    (error: unknown) => error instanceof ProtocolSchemaError
      && /unsupported protocol version/.test(error.message),
  );
  assert.throws(
    () => parseDeviceMessage({ ...valid, ownerId: ID_A }),
    /unknown field: ownerId/,
  );
  assert.throws(
    () => parseDeviceMessage({ ...valid, state: 'completed' }),
    /unknown field: state/,
  );
});

test('action decisions bind the immutable parameters digest', () => {
  assert.throws(() => parseDeviceMessage({
    version: 1,
    type: 'action_decision',
    messageId: ID_A,
    deviceId: ID_B,
    actionId: ID_C,
    decision: 'approved',
    parametersHash: 'not-a-digest',
    fence: 3,
  }), /SHA-256/);
});
