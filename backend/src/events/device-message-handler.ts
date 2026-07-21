import { createHash, randomBytes, randomUUID } from 'node:crypto';
import type { SupabaseClient } from '@supabase/supabase-js';
import {
  parseDeviceMessage,
  ProtocolSchemaError,
  type DeviceMessage,
} from '../protocol/schemas.js';
import {
  replayBatchMessages,
  SupabaseReplayStore,
  type ReplayStore,
} from '../protocol/replay.js';
import {
  canonicalGrantBindings,
  signExecutionGrant,
  verifyExecutionGrantSignature,
} from '../security/execution-grant.js';
import { verifyDeviceResultSignature } from '../security/device-result-signature.js';
import type { ConsumedDeviceTicket } from '../devices/device-service.js';
import type {
  DeviceGatewayHandler,
  DeviceGatewayMessage,
  DeviceGatewayOutboundMessage,
} from './device-gateway.js';
import { validateLocalAction } from '../actions/local-executor-registry.js';

function exactPayload(
  payload: Record<string, unknown>,
  required: string[],
  optional: string[] = [],
): void {
  const allowed = new Set([...required, ...optional]);
  if (
    required.some((key) => !(key in payload))
    || Object.keys(payload).some((key) => !allowed.has(key))
  ) {
    throw new ProtocolSchemaError('Gateway message payload does not match its exact schema');
  }
}

function authoritativeMessage(
  identity: ConsumedDeviceTicket,
  envelope: DeviceGatewayMessage,
): DeviceMessage {
  const common = {
    version: identity.protocolVersion,
    messageId: envelope.id,
    deviceId: identity.deviceId,
    fence: identity.fence,
  };
  switch (envelope.type) {
    case 'ack':
      exactPayload(envelope.payload, ['event_id', 'sequence']);
      return parseDeviceMessage({
        ...common,
        type: 'event_ack',
        eventId: envelope.payload.event_id,
        sequence: envelope.payload.sequence,
      });
    case 'action_decision':
      exactPayload(envelope.payload, ['action_id', 'decision', 'parameters_hash']);
      return parseDeviceMessage({
        ...common,
        type: 'action_decision',
        actionId: envelope.payload.action_id,
        decision: envelope.payload.decision,
        parametersHash: envelope.payload.parameters_hash,
      });
    case 'action_result':
      exactPayload(envelope.payload, [
        'action_id', 'grant_id', 'status', 'result', 'session_id', 'signature',
      ]);
      return parseDeviceMessage({
        ...common,
        type: 'action_result',
        actionId: envelope.payload.action_id,
        grantId: envelope.payload.grant_id,
        status: envelope.payload.status,
        result: envelope.payload.result,
        sessionId: envelope.payload.session_id,
        signature: envelope.payload.signature,
      });
    case 'consume_grant':
      exactPayload(envelope.payload, [
        'action_id', 'grant_id', 'grant_token', 'action_hash', 'parameters_hash',
        'grant_signature', 'registry_version', 'action_type',
        'normalized_parameters', 'capabilities', 'image_digest',
        'workspace_bookmark_id', 'result_disclosure_policy', 'session_id',
        'device_key_fingerprint', 'expires_at', 'transition_id',
      ]);
      return parseDeviceMessage({
        ...common,
        type: 'consume_grant',
        actionId: envelope.payload.action_id,
        grantId: envelope.payload.grant_id,
        grantToken: envelope.payload.grant_token,
        grantSignature: envelope.payload.grant_signature,
        actionHash: envelope.payload.action_hash,
        parametersHash: envelope.payload.parameters_hash,
        registryVersion: envelope.payload.registry_version,
        actionType: envelope.payload.action_type,
        normalizedParameters: envelope.payload.normalized_parameters,
        capabilities: envelope.payload.capabilities,
        imageDigest: envelope.payload.image_digest,
        workspaceBookmarkId: envelope.payload.workspace_bookmark_id,
        resultDisclosurePolicy: envelope.payload.result_disclosure_policy,
        sessionId: envelope.payload.session_id,
        deviceKeyFingerprint: envelope.payload.device_key_fingerprint,
        expiresAt: envelope.payload.expires_at,
        transitionId: envelope.payload.transition_id,
      });
    case 'cancel_run':
      exactPayload(envelope.payload, ['run_id'], ['reason']);
      return parseDeviceMessage({
        ...common,
        type: 'cancel_run',
        runId: envelope.payload.run_id,
        ...(envelope.payload.reason === undefined ? {} : { reason: envelope.payload.reason }),
      });
    default:
      throw new ProtocolSchemaError(`Message type ${envelope.type} is transport-only`);
  }
}

export class SupabaseDeviceMessageHandler implements DeviceGatewayHandler {
  constructor(
    private readonly db: SupabaseClient,
    private readonly replay: ReplayStore = new SupabaseReplayStore(db),
    private readonly replayLimit = 100,
  ) {}

  async onConnect(
    identity: ConsumedDeviceTicket,
  ): Promise<readonly DeviceGatewayOutboundMessage[]> {
    const batch = await this.replay.prepare(identity, this.replayLimit);
    const result: DeviceGatewayOutboundMessage[] = [];
    for (const message of replayBatchMessages(batch, identity.protocolVersion)) {
      result.push(message.type === 'reconnect_contract'
        ? {
            ...message,
            payload: {
              ...message.payload,
              session_id: identity.ticketId,
              fence: identity.fence,
            },
          }
        : message);
      if (
        message.type === 'event'
        && message.payload.event_type === 'execution_grant_issued'
        && message.payload.data
        && typeof message.payload.data === 'object'
      ) {
        const grant = message.payload.data as Record<string, unknown>;
        const contractResponse = await this.db.rpc('danotch_get_execution_grant_contract', {
          p_grant_id: grant.grant_id,
          p_user_id: identity.userId,
          p_device_id: identity.deviceId,
          p_fence: identity.fence,
        });
        if (!contractResponse.error && contractResponse.data) {
          const contract = (
            Array.isArray(contractResponse.data)
              ? contractResponse.data[0]
              : contractResponse.data
          ) as Record<string, unknown>;
          const bindings = this.grantBindings(grant, contract, identity);
          const token = String(grant.grant_token ?? '');
          result.push({
            v: identity.protocolVersion,
            type: 'execution_grant',
            id: String(grant.event_id ?? grant.grant_id),
            payload: {
              ...bindings,
              sequence: grant.sequence,
              grant_token: token,
              grant_signature: signExecutionGrant(bindings, token),
            },
          });
        }
      }
    }
    return result;
  }

  async onMessage(
    identity: ConsumedDeviceTicket,
    envelope: DeviceGatewayMessage,
  ): Promise<readonly DeviceGatewayOutboundMessage[] | void> {
    const message = authoritativeMessage(identity, envelope);
    let operation: PromiseLike<{
      data?: unknown;
      error: { message: string } | null;
    }>;
    switch (message.type) {
      case 'event_ack':
        operation = this.db.rpc('danotch_fenced_acknowledge_event', {
          p_ack_id: message.messageId,
          p_user_id: identity.userId,
          p_device_id: identity.deviceId,
          p_event_id: message.eventId,
          p_device_sequence: message.sequence,
          p_fence: identity.fence,
        });
        break;
      case 'action_decision':
        if (message.decision === 'approved') {
          const grantId = randomUUID();
          const grantToken = randomBytes(32).toString('base64url');
          const grantHash = createHash('sha256').update(grantToken).digest('hex');
          const { data, error } = await this.db.rpc('danotch_fenced_claim_approval_and_mint_grant', {
            p_decision_id: message.messageId,
            p_grant_id: grantId,
            p_action_id: message.actionId,
            p_user_id: identity.userId,
            p_device_id: identity.deviceId,
            p_parameters_hash: message.parametersHash,
            p_grant_hash: grantHash,
            p_grant_token: grantToken,
            p_fence: identity.fence,
            p_expires_at: new Date(Date.now() + 2 * 60_000).toISOString(),
          });
          if (error || !data) throw new Error(error?.message ?? 'Approval claim failed');
          const grant = (Array.isArray(data) ? data[0] : data) as Record<string, unknown>;
          if (grant.grant_token !== grantToken) {
            throw new Error('Grant token binding was not preserved');
          }
          const contractResponse = await this.db.rpc('danotch_get_execution_grant_contract', {
            p_grant_id: grantId,
            p_user_id: identity.userId,
            p_device_id: identity.deviceId,
            p_fence: identity.fence,
          });
          if (contractResponse.error || !contractResponse.data) {
            throw new Error(contractResponse.error?.message ?? 'Grant contract unavailable');
          }
          const contract = (
            Array.isArray(contractResponse.data)
              ? contractResponse.data[0]
              : contractResponse.data
          ) as Record<string, unknown>;
          const bindings = this.grantBindings(grant, contract, identity);
          return [{
            v: identity.protocolVersion,
            type: 'execution_grant',
            id: String(grant.event_id ?? grantId),
            payload: {
              ...bindings,
              sequence: grant.sequence,
              grant_token: grant.grant_token,
              grant_signature: signExecutionGrant(bindings, grantToken),
            },
          }];
        }
        operation = this.db.rpc('danotch_fenced_decide_local_action', {
          p_decision_id: message.messageId,
          p_action_id: message.actionId,
          p_user_id: identity.userId,
          p_device_id: identity.deviceId,
          p_decision: message.decision,
          p_parameters_hash: message.parametersHash,
          p_fence: identity.fence,
        });
        break;
      case 'consume_grant': {
        const bindings = {
          grant_id: message.grantId,
          action_id: message.actionId,
          action_hash: message.actionHash,
          parameters_hash: message.parametersHash,
          registry_version: message.registryVersion,
          action_type: message.actionType,
          normalized_parameters: message.normalizedParameters,
          capabilities: message.capabilities,
          image_digest: message.imageDigest,
          workspace_bookmark_id: message.workspaceBookmarkId,
          result_disclosure_policy: message.resultDisclosurePolicy,
          session_id: message.sessionId,
          device_key_fingerprint: message.deviceKeyFingerprint,
          device_id: identity.deviceId,
          fence: identity.fence,
          expires_at: message.expiresAt,
          transition_id: message.transitionId,
        };
        const contractResponse = await this.db.rpc('danotch_get_execution_grant_contract', {
          p_grant_id: message.grantId,
          p_user_id: identity.userId,
          p_device_id: identity.deviceId,
          p_fence: identity.fence,
        });
        if (contractResponse.error || !contractResponse.data) {
          throw new ProtocolSchemaError('Grant contract is unavailable');
        }
        const contract = (
          Array.isArray(contractResponse.data)
            ? contractResponse.data[0]
            : contractResponse.data
        ) as Record<string, unknown>;
        const authoritativeBindings = this.grantBindings({
          grant_id: message.grantId,
          action_id: message.actionId,
          action_hash: message.actionHash,
          parameters_hash: message.parametersHash,
          normalized_parameters: message.normalizedParameters,
          capabilities: message.capabilities,
          image_digest: message.imageDigest,
          device_id: identity.deviceId,
          fence: identity.fence,
          expires_at: message.expiresAt,
          transition_id: message.transitionId,
        }, contract, identity);
        if (
          message.sessionId !== identity.ticketId
          || Date.parse(message.expiresAt) <= Date.now()
          || !canonicalGrantBindings(bindings).equals(
            canonicalGrantBindings(authoritativeBindings),
          )
          || !verifyExecutionGrantSignature(
            authoritativeBindings,
            message.grantToken,
            message.grantSignature,
          )
        ) {
          throw new ProtocolSchemaError('Grant authorization signature is invalid');
        }
        const grantHash = createHash('sha256').update(message.grantToken).digest('hex');
        operation = this.db.rpc('danotch_fenced_consume_execution_grant', {
          p_consumption_id: message.messageId,
          p_grant_id: message.grantId,
          p_action_id: message.actionId,
          p_user_id: identity.userId,
          p_device_id: identity.deviceId,
          p_grant_hash: grantHash,
          p_action_hash: message.actionHash,
          p_parameters_hash: message.parametersHash,
          p_normalized_parameters: message.normalizedParameters,
          p_capabilities: message.capabilities,
          p_image_digest: message.imageDigest,
          p_fence: identity.fence,
        });
        const { error } = await operation;
        if (error) throw new Error(error.message);
        return [{
          v: identity.protocolVersion,
          type: 'grant_consumed',
          id: message.messageId,
          payload: {
            grant_id: message.grantId,
            action_id: message.actionId,
            transition_id: message.messageId,
          },
        }];
      }
      case 'action_result': {
        if (message.sessionId !== identity.ticketId) {
          throw new ProtocolSchemaError('Result session binding is stale');
        }
        const verificationKeyResponse = await this.db.rpc(
          'danotch_get_device_verification_key',
          {
            p_user_id: identity.userId,
            p_device_id: identity.deviceId,
            p_fence: identity.fence,
          },
        );
        const verificationKey = (
          Array.isArray(verificationKeyResponse.data)
            ? verificationKeyResponse.data[0]
            : verificationKeyResponse.data
        ) as Record<string, unknown> | null;
        if (
          verificationKeyResponse.error
          || !verificationKey
          || !verifyDeviceResultSignature(
            {
              messageId: message.messageId,
              deviceId: identity.deviceId,
              sessionId: identity.ticketId,
              fence: identity.fence,
              actionId: message.actionId,
              grantId: message.grantId,
              status: message.status,
              result: message.result,
            },
            String(verificationKey.public_key ?? ''),
            String(verificationKey.key_algorithm ?? ''),
            message.signature,
          )
        ) {
          throw new ProtocolSchemaError('Result signature is invalid');
        }
        operation = this.db.rpc('danotch_fenced_record_action_result', {
          p_result_id: message.messageId,
          p_action_id: message.actionId,
          p_grant_id: message.grantId,
          p_user_id: identity.userId,
          p_device_id: identity.deviceId,
          p_status: message.status,
          p_result: message.result,
          p_fence: identity.fence,
        });
        const { error } = await operation;
        if (error) throw new Error(error.message);
        return [{
          v: identity.protocolVersion,
          type: 'result_ack',
          id: message.messageId,
          payload: {
            result_id: message.messageId,
            action_id: message.actionId,
            grant_id: message.grantId,
          },
        }];
      }
      case 'cancel_run':
        operation = this.db.rpc('danotch_fenced_cancel_run', {
          p_cancellation_id: message.messageId,
          p_run_id: message.runId,
          p_user_id: identity.userId,
          p_device_id: identity.deviceId,
          p_reason: message.reason ?? '',
          p_fence: identity.fence,
        });
        break;
    }
    const { error } = await operation;
    if (error) throw new Error(error.message);
  }

  private grantBindings(
    grant: Record<string, unknown>,
    contract: Record<string, unknown>,
    identity: ConsumedDeviceTicket,
  ): Record<string, unknown> {
    const registryVersion = String(contract.registry_version ?? '');
    const actionType = String(contract.action_type ?? '');
    const workspaceBookmarkId = String(contract.workspace_bookmark_id ?? '');
    const deviceKeyFingerprint = String(contract.device_key_fingerprint ?? '');
    const disclosure = contract.result_disclosure_policy;
    const validated = validateLocalAction(
      registryVersion,
      actionType,
      grant.normalized_parameters,
      grant.capabilities,
    );
    if (
      validated.actionHash !== grant.action_hash
      || validated.parametersHash !== grant.parameters_hash
      || !/^[A-Za-z0-9._-]{1,128}$/.test(workspaceBookmarkId)
      || !/^[0-9a-f]{64}$/.test(deviceKeyFingerprint)
      || !disclosure
      || typeof disclosure !== 'object'
      || Array.isArray(disclosure)
      || (disclosure as Record<string, unknown>).sensitive_output
        !== validated.capabilities.sensitive_output_disclosure
      || (disclosure as Record<string, unknown>).upload
        !== validated.capabilities.result_upload
    ) {
      throw new ProtocolSchemaError('Execution grant contract is invalid');
    }
    return {
      grant_id: grant.grant_id,
      action_id: grant.action_id,
      action_hash: grant.action_hash,
      parameters_hash: grant.parameters_hash,
      registry_version: registryVersion,
      action_type: actionType,
      normalized_parameters: grant.normalized_parameters,
      capabilities: grant.capabilities,
      image_digest: grant.image_digest,
      workspace_bookmark_id: workspaceBookmarkId,
      result_disclosure_policy: disclosure,
      session_id: identity.ticketId,
      device_key_fingerprint: deviceKeyFingerprint,
      device_id: grant.device_id,
      fence: grant.fence,
      expires_at: grant.expires_at,
      transition_id: grant.transition_id,
    };
  }
}
