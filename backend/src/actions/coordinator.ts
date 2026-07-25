import { createHmac, randomBytes, randomUUID } from 'node:crypto';
import type { Repositories, PendingActionRecord } from '../db/repositories.js';
import type { NotchBridge } from '../events/notch.js';
import {
  LOCAL_EXECUTOR_REGISTRY_VERSION,
  validateLocalAction,
} from './local-executor-registry.js';

const DEFAULT_CAPABILITIES = {
  workspace_mode: 'read_write',
  egress_destinations: [],
  sensitive_file_access: false,
  sensitive_output_disclosure: false,
  result_upload: true,
  limits: {
    cpu_count: 2,
    memory_bytes: 1024 * 1024 * 1024,
    disk_bytes: 2 * 1024 * 1024 * 1024,
    process_count: 64,
    output_bytes: 1024 * 1024,
    timeout_seconds: 300,
  },
} as const;

export class ActionCoordinator {
  private readonly wakeups = new Map<string, Set<() => void>>();
  private readonly connectionResponses = new Map<string, (approved: boolean) => void>();

  constructor(
    private readonly repositories: Repositories,
    private readonly events: NotchBridge,
  ) {}

  offerLocalAction(input: {
    runId: string;
    sessionId: string;
    actionType: string;
    parameters: Record<string, unknown>;
    summary: string;
    workspaceBookmarkId?: string;
  }): PendingActionRecord {
    const validated = validateLocalAction(
      LOCAL_EXECUTOR_REGISTRY_VERSION,
      input.actionType,
      input.parameters,
      DEFAULT_CAPABILITIES,
    );
    const action = this.repositories.createPendingAction(
      input.runId,
      input.actionType,
      input.summary,
      validated.normalizedParameters,
      {
        sessionId: input.sessionId,
        origin: 'local',
        registryVersion: LOCAL_EXECUTOR_REGISTRY_VERSION,
        parametersHash: validated.parametersHash,
        actionHash: validated.actionHash,
        capabilities: validated.capabilities,
        workspaceBookmarkId: input.workspaceBookmarkId ?? `action-${randomUUID()}`,
      },
    );
    this.events.send({
      type: 'local_action_offered',
      action_id: action.id,
      run_id: input.runId,
      session_id: input.sessionId,
      registry_version: action.registry_version,
      action_type: action.action_type,
      summary: action.summary,
      action_hash: action.action_hash,
      parameters_hash: action.parameters_hash,
      normalized_parameters: JSON.parse(action.normalized_parameters_json),
      capabilities: JSON.parse(action.capabilities_json!),
      workspace_bookmark_id: action.workspace_bookmark_id,
      expires_at: action.expires_at,
    });
    return action;
  }

  async waitForTerminal(actionId: string, timeoutMs = 125_000): Promise<PendingActionRecord> {
    const deadline = Date.now() + timeoutMs;
    while (Date.now() < deadline) {
      const action = this.repositories.getPendingAction(actionId);
      if (!action) throw new Error('Pending action disappeared');
      if (['completed', 'failed', 'rejected', 'expired'].includes(action.status)) return action;
      await new Promise<void>((resolve) => {
        const timer = setTimeout(() => {
          this.wakeups.get(actionId)?.delete(done);
          resolve();
        }, Math.min(250, deadline - Date.now()));
        timer.unref();
        const done = () => {
          clearTimeout(timer);
          resolve();
        };
        const listeners = this.wakeups.get(actionId) ?? new Set();
        listeners.add(done);
        this.wakeups.set(actionId, listeners);
      });
    }
    this.repositories.expirePendingActions();
    return this.repositories.getPendingAction(actionId)!;
  }

  handleActionDecision(payload: unknown): boolean {
    const value = object(payload);
    const id = string(value.action_id, 128);
    const action = this.repositories.getPendingAction(id);
    if (!action || action.action_origin !== 'local' || action.status !== 'pending') return false;
    if (
      value.action_hash !== action.action_hash
      || value.parameters_hash !== action.parameters_hash
      || value.expires_at !== action.expires_at
      || value.workspace_bookmark_id !== action.workspace_bookmark_id
    ) return false;
    if (value.decision === 'rejected') {
      const changed = this.repositories.resolvePendingAction(id, 'rejected', value);
      if (changed) this.wake(id);
      return changed;
    }
    if (value.decision !== 'approved') return false;
    if (
      typeof value.workspace_path !== 'string'
      || value.workspace_path.length === 0
      || typeof value.device_id !== 'string'
      || !uuid(value.device_id)
      || typeof value.device_key_fingerprint !== 'string'
      || !/^[a-f0-9]{64}$/.test(value.device_key_fingerprint)
      || typeof value.image_digest !== 'string'
      || !/^sha256:[a-f0-9]{64}$/.test(value.image_digest)
    ) return false;
    if (!this.repositories.resolvePendingAction(id, 'approved', value)) return false;
    const claimed = this.repositories.claimPendingAction(id);
    if (!claimed) return false;
    const request = this.executionRequest(claimed, value);
    this.events.send({ type: 'local_execution_request', ...request });
    this.wake(id);
    return true;
  }

  handleExecutionResult(payload: unknown): boolean {
    const value = object(payload);
    const id = string(value.action_id, 128);
    const requestId = string(value.request_id, 128);
    const action = this.repositories.getPendingAction(id);
    if (!action || action.execution_request_id !== requestId || action.status !== 'executing') return false;
    const result = object(value.result);
    const status = result.status === 'completed' ? 'completed' : 'failed';
    const changed = this.repositories.finishPendingAction(
      id,
      requestId,
      status,
      result,
      status === 'failed' ? String(result.error ?? 'Local execution failed').slice(0, 500) : undefined,
    );
    if (changed) this.wake(id);
    return changed;
  }

  waitForConnectionResponse(requestId: string, timeoutMs = 120_000): Promise<boolean> {
    return new Promise((resolve) => {
      const timer = setTimeout(() => {
        this.connectionResponses.delete(requestId);
        resolve(false);
      }, timeoutMs);
      timer.unref();
      this.connectionResponses.set(requestId, (approved) => {
        clearTimeout(timer);
        this.connectionResponses.delete(requestId);
        resolve(approved);
      });
    });
  }

  handleConnectionResponse(payload: unknown): boolean {
    const value = object(payload);
    const requestId = string(value.request_id, 128);
    if (typeof value.approved !== 'boolean') return false;
    const resolve = this.connectionResponses.get(requestId);
    if (!resolve) return false;
    resolve(value.approved);
    return true;
  }

  private executionRequest(action: PendingActionRecord, decision: Record<string, unknown>): Record<string, unknown> {
    const token = randomBytes(32).toString('base64url');
    const expiresAt = new Date(Math.min(
      new Date(action.expires_at).getTime(),
      Date.now() + 60_000,
    )).toISOString();
    const signed: Record<string, unknown> = {
      grant_id: randomUUID(),
      action_id: action.id,
      action_hash: action.action_hash,
      parameters_hash: action.parameters_hash,
      registry_version: action.registry_version,
      action_type: action.action_type,
      normalized_parameters: JSON.parse(action.normalized_parameters_json),
      capabilities: JSON.parse(action.capabilities_json!),
      image_digest: decision.image_digest,
      workspace_bookmark_id: action.workspace_bookmark_id,
      result_disclosure_policy: {
        sensitive_output: false,
        upload: true,
      },
      session_id: uuid(action.session_id) ? action.session_id : randomUUID(),
      device_key_fingerprint: decision.device_key_fingerprint,
      device_id: decision.device_id,
      fence: 0,
      expires_at: expiresAt,
      transition_id: randomUUID(),
    };
    const canonical = JSON.stringify(sort(signed));
    const signature = createHmac('sha256', Buffer.from(token)).update(canonical).digest('base64url');
    return {
      action_id: action.id,
      request_id: action.execution_request_id,
      grant: {
        ...signed,
        sequence: 1,
        grant_token: token,
        grant_signature: signature,
      },
    };
  }

  private wake(id: string): void {
    for (const wake of this.wakeups.get(id) ?? []) wake();
    this.wakeups.delete(id);
  }
}

function object(value: unknown): Record<string, unknown> {
  if (!value || typeof value !== 'object' || Array.isArray(value)) throw new Error('Invalid IPC payload');
  return value as Record<string, unknown>;
}

function string(value: unknown, max: number): string {
  if (typeof value !== 'string' || value.length === 0 || value.length > max) {
    throw new Error('Invalid IPC string');
  }
  return value;
}

const uuid = (value: unknown): value is string =>
  typeof value === 'string' && /^[a-f0-9]{8}-[a-f0-9]{4}-[1-5][a-f0-9]{3}-[89ab][a-f0-9]{3}-[a-f0-9]{12}$/i.test(value);

function sort(value: unknown): unknown {
  if (Array.isArray(value)) return value.map(sort);
  if (!value || typeof value !== 'object') return value;
  return Object.fromEntries(
    Object.entries(value as Record<string, unknown>)
      .sort(([a], [b]) => a.localeCompare(b))
      .map(([key, child]) => [key, sort(child)]),
  );
}
