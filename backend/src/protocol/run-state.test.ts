import { test } from 'node:test';
import assert from 'node:assert/strict';
import {
  InvalidTransitionError,
  reduceLocalAction,
  reduceRun,
  stateAfterProcessRestart,
  type LocalActionSnapshot,
  type RunSnapshot,
} from './run-state.ts';

const baseRun: RunSnapshot = {
  id: 'run-a',
  ownerId: 'owner-a',
  deviceId: 'device-a',
  state: 'queued',
  revision: 0,
  checkpoint: null,
  appliedTransitions: new Map(),
};

test('run reducer applies ordered transitions and exact duplicates once', () => {
  const transition = {
    transitionId: 'transition-a',
    ownerId: 'owner-a',
    deviceId: 'device-a',
    expectedRevision: 0,
    eventType: 'provider_stream_started' as const,
    targetState: 'provider_streaming' as const,
  };
  const streaming = reduceRun(baseRun, transition);
  assert.equal(streaming.state, 'provider_streaming');
  assert.equal(streaming.revision, 1);
  assert.equal(reduceRun(streaming, transition), streaming);
  assert.throws(
    () => reduceRun(streaming, { ...transition, targetState: 'failed' }),
    (error: unknown) => error instanceof InvalidTransitionError && error.code === 'invalid_transition',
  );
});

test('run reducer rejects out-of-order, late, cross-owner, and cross-device events', () => {
  const transition = {
    transitionId: 'transition-a',
    ownerId: 'owner-a',
    deviceId: 'device-a',
    expectedRevision: 1,
    eventType: 'provider_stream_started' as const,
    targetState: 'provider_streaming' as const,
  };
  assert.throws(() => reduceRun(baseRun, transition), (error: unknown) =>
    error instanceof InvalidTransitionError && error.code === 'out_of_order');
  assert.throws(
    () => reduceRun(baseRun, { ...transition, expectedRevision: 0, ownerId: 'owner-b' }),
    (error: unknown) => error instanceof InvalidTransitionError && error.code === 'owner_mismatch',
  );
  assert.throws(
    () => reduceRun(baseRun, { ...transition, expectedRevision: 0, deviceId: 'device-b' }),
    (error: unknown) => error instanceof InvalidTransitionError && error.code === 'device_mismatch',
  );
  assert.throws(
    () => reduceRun(baseRun, {
      ...transition,
      expectedRevision: 0,
      eventType: 'run_completed',
    }),
    (error: unknown) => error instanceof InvalidTransitionError && error.code === 'invalid_transition',
  );

  const terminal: RunSnapshot = { ...baseRun, state: 'completed' };
  assert.throws(
    () => reduceRun(terminal, { ...transition, expectedRevision: 0 }),
    (error: unknown) => error instanceof InvalidTransitionError && error.code === 'late_transition',
  );
});

test('interrupted provider streams become recoverable terminal runs', () => {
  assert.equal(stateAfterProcessRestart('provider_streaming'), 'failed_recoverable');
  assert.equal(stateAfterProcessRestart('checkpointed'), 'checkpointed');
  assert.equal(stateAfterProcessRestart('queued'), 'queued');
});

test('local actions bind owner, device, and immutable parameters', () => {
  const action: LocalActionSnapshot = {
    id: 'action-a',
    ownerId: 'owner-a',
    deviceId: 'device-a',
    state: 'offered',
    parametersHash: 'abc',
    appliedTransitions: new Map(),
  };
  const approved = reduceLocalAction(action, {
    transitionId: 'decision-a',
    ownerId: 'owner-a',
    deviceId: 'device-a',
    parametersHash: 'abc',
    targetState: 'approved',
  });
  assert.equal(approved.state, 'approved');
  assert.equal(reduceLocalAction(approved, {
    transitionId: 'decision-a',
    ownerId: 'owner-a',
    deviceId: 'device-a',
    parametersHash: 'abc',
    targetState: 'approved',
  }), approved);
  assert.throws(() => reduceLocalAction(action, {
    transitionId: 'forged',
    ownerId: 'owner-a',
    deviceId: 'device-a',
    parametersHash: 'changed',
    targetState: 'approved',
  }), (error: unknown) =>
    error instanceof InvalidTransitionError && error.code === 'parameters_mismatch');
});
