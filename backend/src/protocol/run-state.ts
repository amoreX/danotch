export const RUN_STATES = [
  'queued',
  'provider_streaming',
  'checkpointed',
  'waiting_for_device',
  'cancellation_requested',
  'completed',
  'failed',
  'failed_recoverable',
  'cancelled',
  'expired',
] as const;

export type RunState = typeof RUN_STATES[number];

export const RUN_EVENT_TYPES = [
  'run_created',
  'provider_stream_started',
  'provider_checkpointed',
  'local_action_offered',
  'cancellation_requested',
  'run_completed',
  'run_failed',
  'provider_stream_interrupted',
  'run_cancelled',
  'run_expired',
] as const;

export type RunEventType = typeof RUN_EVENT_TYPES[number];

export interface RunSnapshot {
  id: string;
  ownerId: string;
  deviceId: string | null;
  state: RunState;
  revision: number;
  checkpoint: Record<string, unknown> | null;
  appliedTransitions: ReadonlyMap<string, string>;
}

export interface RunTransition {
  transitionId: string;
  ownerId: string;
  deviceId: string | null;
  expectedRevision: number;
  eventType: RunEventType;
  targetState: RunState;
  payload?: Record<string, unknown>;
  checkpoint?: Record<string, unknown> | null;
}

export type LocalActionState =
  | 'offered'
  | 'approved'
  | 'rejected'
  | 'granted'
  | 'executing'
  | 'completed'
  | 'failed'
  | 'cancelled'
  | 'expired';

export interface LocalActionSnapshot {
  id: string;
  ownerId: string;
  deviceId: string;
  state: LocalActionState;
  parametersHash: string;
  appliedTransitions: ReadonlyMap<string, string>;
}

export interface LocalActionTransition {
  transitionId: string;
  ownerId: string;
  deviceId: string;
  parametersHash: string;
  targetState: LocalActionState;
}

const terminalRunStates = new Set<RunState>([
  'completed', 'failed', 'failed_recoverable', 'cancelled', 'expired',
]);

const eventTargetState: Readonly<Record<Exclude<RunEventType, 'run_created'>, RunState>> = {
  provider_stream_started: 'provider_streaming',
  provider_checkpointed: 'checkpointed',
  local_action_offered: 'waiting_for_device',
  cancellation_requested: 'cancellation_requested',
  run_completed: 'completed',
  run_failed: 'failed',
  provider_stream_interrupted: 'failed_recoverable',
  run_cancelled: 'cancelled',
  run_expired: 'expired',
};

const runTransitions: Readonly<Record<RunState, ReadonlySet<RunState>>> = {
  queued: new Set(['provider_streaming', 'waiting_for_device', 'cancellation_requested', 'failed']),
  provider_streaming: new Set([
    'checkpointed', 'completed', 'failed', 'failed_recoverable', 'cancellation_requested',
  ]),
  checkpointed: new Set([
    'provider_streaming', 'waiting_for_device', 'completed', 'failed', 'cancellation_requested',
  ]),
  waiting_for_device: new Set([
    'checkpointed', 'cancellation_requested', 'cancelled', 'expired', 'failed',
  ]),
  cancellation_requested: new Set(['cancelled', 'failed']),
  completed: new Set(),
  failed: new Set(),
  failed_recoverable: new Set(),
  cancelled: new Set(),
  expired: new Set(),
};

const actionTransitions: Readonly<Record<LocalActionState, ReadonlySet<LocalActionState>>> = {
  offered: new Set(['approved', 'rejected', 'cancelled', 'expired']),
  approved: new Set(['granted', 'cancelled', 'expired']),
  rejected: new Set(),
  granted: new Set(['executing', 'cancelled', 'expired']),
  executing: new Set(['completed', 'failed', 'cancelled']),
  completed: new Set(),
  failed: new Set(),
  cancelled: new Set(),
  expired: new Set(),
};

export class InvalidTransitionError extends Error {
  constructor(
    readonly code:
      | 'owner_mismatch'
      | 'device_mismatch'
      | 'out_of_order'
      | 'late_transition'
      | 'invalid_transition'
      | 'parameters_mismatch',
    message: string,
  ) {
    super(message);
  }
}

export function reduceRun(snapshot: RunSnapshot, transition: RunTransition): RunSnapshot {
  if (snapshot.ownerId !== transition.ownerId) {
    throw new InvalidTransitionError('owner_mismatch', 'run owner does not match transition owner');
  }
  if (snapshot.deviceId !== transition.deviceId) {
    throw new InvalidTransitionError('device_mismatch', 'run device does not match transition device');
  }
  const fingerprint = JSON.stringify({
    ownerId: transition.ownerId,
    deviceId: transition.deviceId,
    eventType: transition.eventType,
    targetState: transition.targetState,
    payload: transition.payload ?? {},
    checkpoint: transition.checkpoint ?? null,
  });
  const applied = snapshot.appliedTransitions.get(transition.transitionId);
  if (applied !== undefined) {
    if (applied !== fingerprint) {
      throw new InvalidTransitionError(
        'invalid_transition',
        'transition ID was reused with different content',
      );
    }
    return snapshot;
  }
  if (transition.expectedRevision !== snapshot.revision) {
    throw new InvalidTransitionError(
      'out_of_order',
      `expected revision ${snapshot.revision}, received ${transition.expectedRevision}`,
    );
  }
  if (terminalRunStates.has(snapshot.state)) {
    throw new InvalidTransitionError('late_transition', `run is terminal: ${snapshot.state}`);
  }
  if (
    transition.eventType === 'run_created'
    || eventTargetState[transition.eventType] !== transition.targetState
  ) {
    throw new InvalidTransitionError(
      'invalid_transition',
      `${transition.eventType} cannot produce ${transition.targetState}`,
    );
  }
  if (!runTransitions[snapshot.state].has(transition.targetState)) {
    throw new InvalidTransitionError(
      'invalid_transition',
      `${snapshot.state} cannot transition to ${transition.targetState}`,
    );
  }

  return {
    ...snapshot,
    state: transition.targetState,
    revision: snapshot.revision + 1,
    checkpoint: transition.checkpoint === undefined
      ? snapshot.checkpoint
      : transition.checkpoint,
    appliedTransitions: new Map([
      ...snapshot.appliedTransitions,
      [transition.transitionId, fingerprint],
    ]),
  };
}

export function reduceLocalAction(
  snapshot: LocalActionSnapshot,
  transition: LocalActionTransition,
): LocalActionSnapshot {
  if (snapshot.ownerId !== transition.ownerId) {
    throw new InvalidTransitionError('owner_mismatch', 'action owner does not match');
  }
  if (snapshot.deviceId !== transition.deviceId) {
    throw new InvalidTransitionError('device_mismatch', 'action device does not match');
  }
  if (snapshot.parametersHash !== transition.parametersHash) {
    throw new InvalidTransitionError('parameters_mismatch', 'action parameters changed after offer');
  }
  const fingerprint = JSON.stringify({
    ownerId: transition.ownerId,
    deviceId: transition.deviceId,
    parametersHash: transition.parametersHash,
    targetState: transition.targetState,
  });
  const applied = snapshot.appliedTransitions.get(transition.transitionId);
  if (applied !== undefined) {
    if (applied !== fingerprint) {
      throw new InvalidTransitionError(
        'invalid_transition',
        'transition ID was reused with different content',
      );
    }
    return snapshot;
  }
  if (!actionTransitions[snapshot.state].has(transition.targetState)) {
    const terminal = actionTransitions[snapshot.state].size === 0;
    throw new InvalidTransitionError(
      terminal ? 'late_transition' : 'invalid_transition',
      `${snapshot.state} cannot transition to ${transition.targetState}`,
    );
  }
  return {
    ...snapshot,
    state: transition.targetState,
    appliedTransitions: new Map([
      ...snapshot.appliedTransitions,
      [transition.transitionId, fingerprint],
    ]),
  };
}

/**
 * Startup recovery never resumes uncertain provider output. Only durable safe
 * boundaries are restartable; an active stream is terminal and explicitly
 * recoverable by creating a new run.
 */
export function stateAfterProcessRestart(state: RunState): RunState {
  return state === 'provider_streaming' ? 'failed_recoverable' : state;
}
