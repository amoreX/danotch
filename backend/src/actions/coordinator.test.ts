import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import { test } from 'node:test';
import { openDatabase } from '../db/database.ts';
import { Repositories } from '../db/repositories.ts';
import type { NotchBridge } from '../events/notch.ts';
import { ActionCoordinator } from './coordinator.ts';

test('local action decisions validate immutable bindings and terminal results are idempotent', () => {
  const db = openDatabase(':memory:');
  try {
    const repositories = new Repositories(db);
    const events: Array<Record<string, unknown>> = [];
    const bridge = { send(event: Record<string, unknown>) { events.push(event); } } as NotchBridge;
    const coordinator = new ActionCoordinator(repositories, bridge);
    const sessionId = randomUUID();
    const runId = repositories.createRun({ kind: 'chat', input: {} });
    const action = coordinator.offerLocalAction({
      runId,
      sessionId,
      actionType: 'shell.execute',
      parameters: { command: 'npm test' },
      summary: 'Run tests',
    });
    assert.equal(coordinator.handleActionDecision({
      action_id: action.id,
      decision: 'approved',
      action_hash: '0'.repeat(64),
      parameters_hash: action.parameters_hash,
      workspace_bookmark_id: action.workspace_bookmark_id,
      workspace_path: '/tmp/workspace',
      high_risk_shell: true,
      expires_at: action.expires_at,
      device_id: randomUUID(),
      device_key_fingerprint: 'a'.repeat(64),
      image_digest: `sha256:${'b'.repeat(64)}`,
    }), false);
    const deviceId = randomUUID();
    assert.equal(coordinator.handleActionDecision({
      action_id: action.id,
      decision: 'approved',
      action_hash: action.action_hash,
      parameters_hash: action.parameters_hash,
      workspace_bookmark_id: action.workspace_bookmark_id,
      workspace_path: '/tmp/workspace',
      high_risk_shell: true,
      expires_at: action.expires_at,
      device_id: deviceId,
      device_key_fingerprint: 'a'.repeat(64),
      image_digest: `sha256:${'b'.repeat(64)}`,
    }), true);
    const request = events.at(-1)!;
    assert.equal(request.type, 'local_execution_request');
    const grant = request.grant as Record<string, unknown>;
    assert.equal(grant.device_id, deviceId);
    assert.equal(grant.session_id, sessionId);
    assert.equal(typeof grant.grant_signature, 'string');
    const resultPayload = {
      action_id: action.id,
      request_id: request.request_id,
      result: {
        status: 'completed',
        exit_code: 0,
        stdout: 'ok',
        stderr: '',
        truncated: false,
        duration_ms: 12,
        redactions: 0,
      },
    };
    assert.equal(coordinator.handleExecutionResult(resultPayload), true);
    assert.equal(coordinator.handleExecutionResult(resultPayload), false);
    assert.equal(repositories.getPendingAction(action.id)?.status, 'completed');
  } finally {
    db.close();
  }
});
