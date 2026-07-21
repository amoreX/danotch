import assert from 'node:assert/strict';
import { generateKeyPairSync, sign } from 'node:crypto';
import { test } from 'node:test';
import type { SupabaseClient } from '@supabase/supabase-js';
import { signExecutionGrant } from '../security/execution-grant.ts';
import { deviceResultSigningPayload } from '../security/device-result-signature.ts';
import { validateLocalAction } from '../actions/local-executor-registry.ts';

const localCapabilities = {
  workspace_mode: 'read_only',
  egress_destinations: [],
  sensitive_file_access: false,
  sensitive_output_disclosure: false,
  result_upload: false,
  limits: {
    cpu_count: 1,
    memory_bytes: 268_435_456,
    disk_bytes: 536_870_912,
    process_count: 32,
    output_bytes: 65_536,
    timeout_seconds: 30,
  },
};
const localParameters = { path: 'Sources', depth: 2 };
const localAction = validateLocalAction(
  '1',
  'workspace.inspect',
  localParameters,
  localCapabilities,
);
import { SupabaseDeviceMessageHandler } from './device-message-handler.ts';

const identity = {
  userId: '10000000-0000-4000-8000-000000000001',
  deviceId: '20000000-0000-4000-8000-000000000002',
  protocolVersion: 1,
  fence: 7,
  ticketId: '30000000-0000-4000-8000-000000000003',
};

test('device operations derive owner, device, and fence only from consumed ticket identity', async () => {
  const calls: Array<{ name: string; args: Record<string, unknown> }> = [];
  const db = {
    rpc(name: string, args: Record<string, unknown>) {
      calls.push({ name, args });
      return Promise.resolve({ error: null });
    },
  } as unknown as SupabaseClient;
  const handler = new SupabaseDeviceMessageHandler(db);
  await handler.onMessage(identity, {
    v: 1,
    type: 'ack',
    id: '40000000-0000-4000-8000-000000000004',
    payload: {
      event_id: '50000000-0000-4000-8000-000000000005',
      sequence: 9,
    },
  });
  assert.deepEqual(calls, [{
    name: 'danotch_fenced_acknowledge_event',
    args: {
      p_ack_id: '40000000-0000-4000-8000-000000000004',
      p_user_id: identity.userId,
      p_device_id: identity.deviceId,
      p_event_id: '50000000-0000-4000-8000-000000000005',
      p_device_sequence: 9,
      p_fence: 7,
    },
  }]);
});

test('operation payloads reject identity fields and unknown schema data', async () => {
  const db = {
    rpc() {
      throw new Error('must not reach database');
    },
  } as unknown as SupabaseClient;
  const handler = new SupabaseDeviceMessageHandler(db);
  await assert.rejects(
    handler.onMessage(identity, {
      v: 1,
      type: 'ack',
      id: '40000000-0000-4000-8000-000000000004',
      payload: {
        event_id: '50000000-0000-4000-8000-000000000005',
        sequence: 9,
        device_id: '60000000-0000-4000-8000-000000000006',
      },
    }),
    /exact schema/,
  );
});

test('approval emits a grant only from the atomic claim response', async () => {
  const calls: Array<{ name: string; args: Record<string, unknown> }> = [];
  const db = {
    rpc(name: string, args: Record<string, unknown>) {
      calls.push({ name, args });
      if (name === 'danotch_get_execution_grant_contract') {
        return Promise.resolve({
          error: null,
          data: {
            registry_version: '1',
            action_type: 'workspace.inspect',
            workspace_bookmark_id: 'workspace-test',
            result_disclosure_policy: { sensitive_output: false, upload: false },
            device_key_fingerprint: 'd'.repeat(64),
          },
        });
      }
      return Promise.resolve({
        error: null,
        data: {
          event_id: '70000000-0000-4000-8000-000000000007',
          grant_id: '80000000-0000-4000-8000-000000000008',
          action_id: '50000000-0000-4000-8000-000000000005',
          grant_token: args.p_grant_token,
          action_hash: localAction.actionHash,
          parameters_hash: localAction.parametersHash,
          normalized_parameters: localParameters,
          capabilities: localCapabilities,
          image_digest: `sha256:${'c'.repeat(64)}`,
          device_id: identity.deviceId,
          fence: identity.fence,
          expires_at: '2099-07-21T01:00:00.000Z',
          transition_id: '40000000-0000-4000-8000-000000000004',
        },
      });
    },
  } as unknown as SupabaseClient;
  const messages = await new SupabaseDeviceMessageHandler(db).onMessage(identity, {
    v: 1,
    type: 'action_decision',
    id: '40000000-0000-4000-8000-000000000004',
    payload: {
      action_id: '50000000-0000-4000-8000-000000000005',
      decision: 'approved',
      parameters_hash: localAction.parametersHash,
    },
  });
  assert.equal(calls[0].name, 'danotch_fenced_claim_approval_and_mint_grant');
  assert.equal(messages?.[0].type, 'execution_grant');
  assert.equal(messages?.[0].payload.grant_id, '80000000-0000-4000-8000-000000000008');
  assert.equal(typeof messages?.[0].payload.grant_token, 'string');
  assert.equal(messages?.[0].payload.registry_version, '1');
  assert.equal(typeof messages?.[0].payload.grant_signature, 'string');
});

test('cancellation or expiry race fails before a grant can be emitted', async () => {
  const db = {
    rpc() {
      return Promise.resolve({
        data: null,
        error: { message: 'run is cancelled, expired, or not waiting for initiating device' },
      });
    },
  } as unknown as SupabaseClient;
  await assert.rejects(
    new SupabaseDeviceMessageHandler(db).onMessage(identity, {
      v: 1,
      type: 'action_decision',
      id: '40000000-0000-4000-8000-000000000004',
      payload: {
        action_id: '50000000-0000-4000-8000-000000000005',
        decision: 'approved',
        parameters_hash: 'b'.repeat(64),
      },
    }),
    /cancelled, expired/,
  );
});

test('grant consumption binds every field, retries one transition, and rejects reuse', async () => {
  let calls = 0;
  const db = {
    rpc(name: string, args: Record<string, unknown>) {
      if (name === 'danotch_get_execution_grant_contract') {
        return Promise.resolve({
          error: null,
          data: {
            registry_version: '1',
            action_type: 'workspace.inspect',
            workspace_bookmark_id: 'workspace-test',
            result_disclosure_policy: { sensitive_output: false, upload: false },
            device_key_fingerprint: 'd'.repeat(64),
          },
        });
      }
      calls += 1;
      assert.equal(name, 'danotch_fenced_consume_execution_grant');
      assert.equal(args.p_action_hash, localAction.actionHash);
      assert.deepEqual(args.p_normalized_parameters, localParameters);
      assert.deepEqual(args.p_capabilities, localCapabilities);
      return Promise.resolve(calls <= 2
        ? { data: 'consumed', error: null }
        : { data: null, error: { message: 'grant was already consumed by another transition' } });
    },
  } as unknown as SupabaseClient;
  const handler = new SupabaseDeviceMessageHandler(db);
  const bindings = {
    grant_id: '60000000-0000-4000-8000-000000000006',
    action_id: '50000000-0000-4000-8000-000000000005',
    action_hash: localAction.actionHash,
    parameters_hash: localAction.parametersHash,
    registry_version: '1',
    action_type: 'workspace.inspect',
    normalized_parameters: localParameters,
    capabilities: localCapabilities,
    image_digest: `sha256:${'c'.repeat(64)}`,
    workspace_bookmark_id: 'workspace-test',
    result_disclosure_policy: { sensitive_output: false, upload: false },
    session_id: identity.ticketId,
    device_key_fingerprint: 'd'.repeat(64),
    device_id: identity.deviceId,
    fence: identity.fence,
    expires_at: '2099-07-21T01:00:00.000Z',
    transition_id: '90000000-0000-4000-8000-000000000009',
  };
  const envelope = {
    v: 1,
    type: 'consume_grant' as const,
    id: '40000000-0000-4000-8000-000000000004',
    payload: {
      action_id: '50000000-0000-4000-8000-000000000005',
      grant_id: '60000000-0000-4000-8000-000000000006',
      grant_token: 'x'.repeat(43),
      grant_signature: signExecutionGrant(bindings, 'x'.repeat(43)),
      action_hash: bindings.action_hash,
      parameters_hash: bindings.parameters_hash,
      registry_version: bindings.registry_version,
      action_type: bindings.action_type,
      normalized_parameters: bindings.normalized_parameters,
      capabilities: bindings.capabilities,
      image_digest: bindings.image_digest,
      workspace_bookmark_id: bindings.workspace_bookmark_id,
      result_disclosure_policy: bindings.result_disclosure_policy,
      session_id: bindings.session_id,
      device_key_fingerprint: bindings.device_key_fingerprint,
      expires_at: bindings.expires_at,
      transition_id: bindings.transition_id,
    },
  };
  assert.equal((await handler.onMessage(identity, envelope))?.[0].type, 'grant_consumed');
  assert.equal((await handler.onMessage(identity, envelope))?.[0].type, 'grant_consumed');
  await assert.rejects(
    handler.onMessage(identity, {
      ...envelope,
      id: '70000000-0000-4000-8000-000000000007',
    }),
    /another transition/,
  );
});

test('signed fenced result is acknowledged idempotently', async () => {
  const keys = generateKeyPairSync('ec', { namedCurve: 'prime256v1' });
  const publicKey = keys.publicKey.export({ type: 'spki', format: 'pem' }).toString();
  const resultID = '40000000-0000-4000-8000-000000000004';
  const actionID = '50000000-0000-4000-8000-000000000005';
  const grantID = '60000000-0000-4000-8000-000000000006';
  const result = { stdout: 'ok', exit_code: 0 };
  const signature = sign('sha256', deviceResultSigningPayload({
    messageId: resultID,
    deviceId: identity.deviceId,
    sessionId: identity.ticketId,
    fence: identity.fence,
    actionId: actionID,
    grantId: grantID,
    status: 'completed',
    result,
  }), keys.privateKey).toString('base64url');
  let writes = 0;
  const db = {
    rpc(name: string) {
      if (name === 'danotch_get_device_verification_key') {
        return Promise.resolve({
          error: null,
          data: {
            public_key: publicKey,
            key_algorithm: 'P-256',
            key_fingerprint: 'd'.repeat(64),
          },
        });
      }
      assert.equal(name, 'danotch_fenced_record_action_result');
      writes += 1;
      return Promise.resolve({ data: 'completed', error: null });
    },
  } as unknown as SupabaseClient;
  const handler = new SupabaseDeviceMessageHandler(db);
  const envelope = {
    v: 1,
    type: 'action_result' as const,
    id: resultID,
    payload: {
      action_id: actionID,
      grant_id: grantID,
      status: 'completed',
      result,
      session_id: identity.ticketId,
      signature,
    },
  };
  assert.equal((await handler.onMessage(identity, envelope))?.[0].type, 'result_ack');
  assert.equal((await handler.onMessage(identity, envelope))?.[0].type, 'result_ack');
  assert.equal(writes, 2);
  await assert.rejects(
    handler.onMessage(identity, {
      ...envelope,
      payload: { ...envelope.payload, session_id: actionID },
    }),
    /session binding is stale/,
  );
});
