export const PROTOCOL_VERSION = 1 as const;

export type DeviceMessage =
  | {
      version: 1;
      type: 'event_ack';
      messageId: string;
      deviceId: string;
      eventId: string;
      sequence: number;
      fence: number;
    }
  | {
      version: 1;
      type: 'action_decision';
      messageId: string;
      deviceId: string;
      actionId: string;
      decision: 'approved' | 'rejected';
      parametersHash: string;
      fence: number;
    }
  | {
      version: 1;
      type: 'consume_grant';
      messageId: string;
      deviceId: string;
      actionId: string;
      grantId: string;
      grantToken: string;
      grantSignature: string;
      actionHash: string;
      parametersHash: string;
      registryVersion: string;
      actionType: string;
      normalizedParameters: Record<string, unknown>;
      capabilities: Record<string, unknown>;
      imageDigest: string;
      workspaceBookmarkId: string;
      resultDisclosurePolicy: Record<string, unknown>;
      sessionId: string;
      deviceKeyFingerprint: string;
      expiresAt: string;
      transitionId: string;
      fence: number;
    }
  | {
      version: 1;
      type: 'action_result';
      messageId: string;
      deviceId: string;
      actionId: string;
      grantId: string;
      status: 'completed' | 'failed' | 'cancelled';
      result: Record<string, unknown>;
      sessionId: string;
      signature: string;
      fence: number;
    }
  | {
      version: 1;
      type: 'cancel_run';
      messageId: string;
      deviceId: string;
      runId: string;
      reason?: string;
      fence: number;
    };

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
const SHA256 = /^[0-9a-f]{64}$/i;
const TOKEN = /^[A-Za-z0-9_-]{43}$/;
const IMAGE_DIGEST = /^sha256:[0-9a-f]{64}$/i;

function record(value: unknown, label: string): Record<string, unknown> {
  if (!value || typeof value !== 'object' || Array.isArray(value)) {
    throw new ProtocolSchemaError(`${label} must be an object`);
  }
  return value as Record<string, unknown>;
}

function exactKeys(
  value: Record<string, unknown>,
  required: string[],
  optional: string[] = [],
): void {
  const allowed = new Set([...required, ...optional]);
  for (const key of Object.keys(value)) {
    if (!allowed.has(key)) throw new ProtocolSchemaError(`unknown field: ${key}`);
  }
  for (const key of required) {
    if (!(key in value)) throw new ProtocolSchemaError(`missing field: ${key}`);
  }
}

function uuid(value: unknown, label: string): string {
  if (typeof value !== 'string' || !UUID.test(value)) {
    throw new ProtocolSchemaError(`${label} must be a UUID`);
  }
  return value;
}

function positiveInteger(value: unknown, label: string): number {
  if (!Number.isSafeInteger(value) || (value as number) < 1) {
    throw new ProtocolSchemaError(`${label} must be a positive integer`);
  }
  return value as number;
}

function fence(value: unknown): number {
  if (!Number.isSafeInteger(value) || (value as number) < 0) {
    throw new ProtocolSchemaError('fence must be a non-negative integer');
  }
  return value as number;
}

export class ProtocolSchemaError extends Error {
  readonly code = 'invalid_protocol_message';
}

export function parseDeviceMessage(input: unknown): DeviceMessage {
  const value = record(input, 'message');
  if (value.version !== PROTOCOL_VERSION) {
    throw new ProtocolSchemaError(`unsupported protocol version: ${String(value.version)}`);
  }
  if (typeof value.type !== 'string') throw new ProtocolSchemaError('type must be a string');

  const common = {
    version: PROTOCOL_VERSION,
    messageId: uuid(value.messageId, 'messageId'),
    deviceId: uuid(value.deviceId, 'deviceId'),
    fence: fence(value.fence),
  };

  switch (value.type) {
    case 'event_ack':
      exactKeys(value, ['version', 'type', 'messageId', 'deviceId', 'eventId', 'sequence', 'fence']);
      return {
        ...common,
        type: value.type,
        eventId: uuid(value.eventId, 'eventId'),
        sequence: positiveInteger(value.sequence, 'sequence'),
      };
    case 'action_decision':
      exactKeys(value, [
        'version', 'type', 'messageId', 'deviceId', 'actionId',
        'decision', 'parametersHash', 'fence',
      ]);
      if (value.decision !== 'approved' && value.decision !== 'rejected') {
        throw new ProtocolSchemaError('decision must be approved or rejected');
      }
      if (typeof value.parametersHash !== 'string' || !SHA256.test(value.parametersHash)) {
        throw new ProtocolSchemaError('parametersHash must be a SHA-256 digest');
      }
      return {
        ...common,
        type: value.type,
        actionId: uuid(value.actionId, 'actionId'),
        decision: value.decision,
        parametersHash: value.parametersHash.toLowerCase(),
      };
    case 'action_result':
      exactKeys(value, [
        'version', 'type', 'messageId', 'deviceId', 'actionId',
        'grantId', 'status', 'result', 'sessionId', 'signature', 'fence',
      ]);
      if (!['completed', 'failed', 'cancelled'].includes(String(value.status))) {
        throw new ProtocolSchemaError('invalid action result status');
      }
      if (typeof value.signature !== 'string' || value.signature.length > 128) {
        throw new ProtocolSchemaError('invalid action result signature');
      }
      return {
        ...common,
        type: value.type,
        actionId: uuid(value.actionId, 'actionId'),
        grantId: uuid(value.grantId, 'grantId'),
        status: value.status as 'completed' | 'failed' | 'cancelled',
        result: record(value.result, 'result'),
        sessionId: uuid(value.sessionId, 'sessionId'),
        signature: value.signature,
      };
    case 'consume_grant':
      exactKeys(value, [
        'version', 'type', 'messageId', 'deviceId', 'actionId', 'grantId',
        'grantToken', 'grantSignature', 'actionHash', 'parametersHash',
        'registryVersion', 'actionType', 'normalizedParameters',
        'capabilities', 'imageDigest', 'workspaceBookmarkId',
        'resultDisclosurePolicy', 'sessionId', 'deviceKeyFingerprint',
        'expiresAt', 'transitionId', 'fence',
      ]);
      if (typeof value.grantToken !== 'string' || !TOKEN.test(value.grantToken)) {
        throw new ProtocolSchemaError('grantToken must be a 256-bit base64url token');
      }
      if (
        typeof value.actionHash !== 'string'
        || !SHA256.test(value.actionHash)
        || typeof value.parametersHash !== 'string'
        || !SHA256.test(value.parametersHash)
      ) {
        throw new ProtocolSchemaError('grant action and parameter hashes must be SHA-256 digests');
      }
      if (typeof value.imageDigest !== 'string' || !IMAGE_DIGEST.test(value.imageDigest)) {
        throw new ProtocolSchemaError('imageDigest must be a pinned SHA-256 image digest');
      }
      if (
        typeof value.grantSignature !== 'string'
        || !TOKEN.test(value.grantSignature)
        || typeof value.registryVersion !== 'string'
        || value.registryVersion.length > 32
        || typeof value.actionType !== 'string'
        || value.actionType.length > 128
        || typeof value.workspaceBookmarkId !== 'string'
        || !/^[A-Za-z0-9._-]{1,128}$/.test(value.workspaceBookmarkId)
        || typeof value.deviceKeyFingerprint !== 'string'
        || !SHA256.test(value.deviceKeyFingerprint)
        || typeof value.expiresAt !== 'string'
        || !Number.isFinite(Date.parse(value.expiresAt))
      ) {
        throw new ProtocolSchemaError('grant authorization bindings are malformed');
      }
      return {
        ...common,
        type: value.type,
        actionId: uuid(value.actionId, 'actionId'),
        grantId: uuid(value.grantId, 'grantId'),
        grantToken: value.grantToken,
        grantSignature: value.grantSignature,
        actionHash: value.actionHash.toLowerCase(),
        parametersHash: value.parametersHash.toLowerCase(),
        registryVersion: value.registryVersion,
        actionType: value.actionType,
        normalizedParameters: record(value.normalizedParameters, 'normalizedParameters'),
        capabilities: record(value.capabilities, 'capabilities'),
        imageDigest: value.imageDigest.toLowerCase(),
        workspaceBookmarkId: value.workspaceBookmarkId,
        resultDisclosurePolicy: record(
          value.resultDisclosurePolicy,
          'resultDisclosurePolicy',
        ),
        sessionId: uuid(value.sessionId, 'sessionId'),
        deviceKeyFingerprint: value.deviceKeyFingerprint.toLowerCase(),
        expiresAt: value.expiresAt,
        transitionId: uuid(value.transitionId, 'transitionId'),
      };
    case 'cancel_run':
      exactKeys(
        value,
        ['version', 'type', 'messageId', 'deviceId', 'runId', 'fence'],
        ['reason'],
      );
      if (value.reason !== undefined && (typeof value.reason !== 'string' || value.reason.length > 500)) {
        throw new ProtocolSchemaError('reason must be at most 500 characters');
      }
      return {
        ...common,
        type: value.type,
        runId: uuid(value.runId, 'runId'),
        ...(value.reason === undefined ? {} : { reason: value.reason }),
      };
    default:
      throw new ProtocolSchemaError(`unsupported message type: ${value.type}`);
  }
}
