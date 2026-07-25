import { createHash, randomUUID } from 'node:crypto';
import type { SqliteDatabase } from './database.js';
import { computeNextRun } from '../scheduler/compute-next.js';
import type { ProviderType } from '../providers/types.js';

const now = () => new Date().toISOString();
const json = (value: unknown) => JSON.stringify(value ?? {});

export interface ProviderPreference {
  id: string;
  provider: ProviderType;
  model_id: string;
  base_url: string | null;
  keychain_account: string;
  is_active: number;
  verified_at: string | null;
  created_at: string;
  updated_at: string;
}

export interface ScheduleRecord {
  id: string;
  name: string;
  prompt: string;
  task_type: 'scheduled' | 'poll';
  cron: string | null;
  interval_ms: number | null;
  provider_id: string | null;
  model_id: string | null;
  base_url: string | null;
  notify_user: number;
  enabled: number;
  next_run_at: string;
  last_run_at: string | null;
  run_count: number;
  last_status: string | null;
  last_result: string | null;
  claim_id: string | null;
  claim_until: string | null;
  created_at: string;
  updated_at: string;
}

export type IntegrationType = 'gmail' | 'googlecalendar' | 'googledocs' | 'github';
export interface PendingActionRecord {
  id: string;
  run_id: string | null;
  session_id: string | null;
  action_origin: 'local' | 'composio';
  action_type: string;
  summary: string;
  payload_json: string;
  normalized_parameters_json: string;
  parameters_hash: string;
  action_hash: string;
  registry_version: string;
  capabilities_json: string | null;
  workspace_bookmark_id: string | null;
  status: 'pending' | 'approved' | 'rejected' | 'expired' | 'executing' | 'completed' | 'failed';
  idempotency_key: string;
  expires_at: string;
  decision_json: string | null;
  execution_request_id: string | null;
  result_json: string | null;
  error: string | null;
  created_at: string;
  resolved_at: string | null;
  executed_at: string | null;
}

export class Repositories {
  constructor(readonly db: SqliteDatabase) {}

  listProviders(): ProviderPreference[] {
    return this.db.prepare(
      `SELECT id, provider, model_id, base_url, keychain_account, is_active,
              verified_at, created_at, updated_at
         FROM provider_preferences ORDER BY is_active DESC, updated_at DESC`,
    ).all() as unknown as ProviderPreference[];
  }

  getProvider(id?: string | null): ProviderPreference | undefined {
    const statement = id
      ? this.db.prepare('SELECT * FROM provider_preferences WHERE id = ?')
      : this.db.prepare('SELECT * FROM provider_preferences WHERE is_active = 1');
    return statement.get(...(id ? [id] : [])) as unknown as ProviderPreference | undefined;
  }

  getProviderByType(provider: ProviderType): ProviderPreference | undefined {
    return this.db.prepare('SELECT * FROM provider_preferences WHERE provider = ?')
      .get(provider) as unknown as ProviderPreference | undefined;
  }

  saveProvider(input: {
    id?: string;
    provider: ProviderType;
    modelId: string;
    baseUrl?: string | null;
    keychainAccount: string;
    active?: boolean;
  }): ProviderPreference {
    const id = input.id ?? randomUUID();
    const timestamp = now();
    this.db.exec('BEGIN IMMEDIATE');
    try {
      if (input.active) this.db.exec('UPDATE provider_preferences SET is_active = 0');
      this.db.prepare(`
        INSERT INTO provider_preferences
          (id, provider, model_id, base_url, keychain_account, is_active, created_at, updated_at)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(id) DO UPDATE SET provider=excluded.provider, model_id=excluded.model_id,
          base_url=excluded.base_url, keychain_account=excluded.keychain_account,
          is_active=excluded.is_active, verified_at=NULL, updated_at=excluded.updated_at
      `).run(
        id, input.provider, input.modelId, input.baseUrl ?? null, input.keychainAccount,
        input.active ? 1 : 0, timestamp, timestamp,
      );
      this.db.exec('COMMIT');
    } catch (error) {
      this.db.exec('ROLLBACK');
      throw error;
    }
    return this.getProvider(id)!;
  }

  activateProvider(id: string): boolean {
    this.db.exec('BEGIN IMMEDIATE');
    try {
      this.db.exec('UPDATE provider_preferences SET is_active = 0');
      const result = this.db.prepare(
        'UPDATE provider_preferences SET is_active = 1, updated_at = ? WHERE id = ?',
      ).run(now(), id);
      this.db.exec('COMMIT');
      return result.changes === 1;
    } catch (error) {
      this.db.exec('ROLLBACK');
      throw error;
    }
  }

  activateProviderType(provider: ProviderType): boolean {
    const preference = this.getProviderByType(provider);
    return preference ? this.activateProvider(preference.id) : false;
  }

  markProviderVerified(id: string): void {
    this.db.prepare('UPDATE provider_preferences SET verified_at = ?, updated_at = ? WHERE id = ?')
      .run(now(), now(), id);
  }

  deleteProvider(id: string): boolean {
    return this.db.prepare('DELETE FROM provider_preferences WHERE id = ?').run(id).changes === 1;
  }

  deleteProviderType(provider: ProviderType): boolean {
    return this.db.prepare('DELETE FROM provider_preferences WHERE provider = ?').run(provider).changes === 1;
  }

  getOrCreateComposioUserId(): string {
    const existing = this.db.prepare(
      'SELECT composio_user_id FROM local_identity WHERE singleton=1',
    ).get() as { composio_user_id: string } | undefined;
    if (existing) return existing.composio_user_id;
    const id = `local_${randomUUID()}`;
    this.db.prepare(
      'INSERT OR IGNORE INTO local_identity(singleton,composio_user_id,created_at) VALUES(1,?,?)',
    ).run(id, now());
    return (this.db.prepare(
      'SELECT composio_user_id FROM local_identity WHERE singleton=1',
    ).get() as { composio_user_id: string }).composio_user_id;
  }

  listIntegrationConfigs(): Array<{
    app_type: IntegrationType; toolkit_slug: string; auth_config_id: string | null; updated_at: string;
  }> {
    return this.db.prepare('SELECT * FROM integration_config ORDER BY app_type').all() as never;
  }

  getIntegrationConfig(appType: IntegrationType): {
    app_type: IntegrationType; toolkit_slug: string; auth_config_id: string | null; updated_at: string;
  } | undefined {
    return this.db.prepare('SELECT * FROM integration_config WHERE app_type=?')
      .get(appType) as never;
  }

  saveIntegrationConfig(appType: IntegrationType, toolkitSlug: string, authConfigId: string | null): void {
    this.db.prepare(`
      INSERT INTO integration_config(app_type,toolkit_slug,auth_config_id,updated_at)
      VALUES(?,?,?,?) ON CONFLICT(app_type) DO UPDATE SET
        toolkit_slug=excluded.toolkit_slug,auth_config_id=excluded.auth_config_id,
        updated_at=excluded.updated_at
    `).run(appType, toolkitSlug, authConfigId, now());
  }

  clearConnection(appType: IntegrationType): void {
    this.db.prepare('DELETE FROM connections WHERE app_type=?').run(appType);
  }

  listSchedules(): ScheduleRecord[] {
    return this.db.prepare('SELECT * FROM schedules ORDER BY created_at DESC').all() as unknown as ScheduleRecord[];
  }

  getSchedule(id: string): ScheduleRecord | undefined {
    return this.db.prepare('SELECT * FROM schedules WHERE id = ?').get(id) as unknown as ScheduleRecord | undefined;
  }

  saveSchedule(input: {
    id?: string;
    name: string;
    prompt: string;
    taskType: 'scheduled' | 'poll';
    cron?: string | null;
    intervalMs?: number | null;
    providerId?: string | null;
    modelId?: string | null;
    baseUrl?: string | null;
    notifyUser?: boolean;
    enabled?: boolean;
  }): ScheduleRecord {
    const id = input.id ?? randomUUID();
    const timestamp = now();
    const nextRunAt = computeNextRun({
      cron: input.cron ?? null,
      intervalMs: input.intervalMs ?? null,
      from: new Date(),
    }).toISOString();
    this.db.prepare(`
      INSERT INTO schedules
        (id,name,prompt,task_type,cron,interval_ms,provider_id,model_id,base_url,notify_user,
         enabled,next_run_at,created_at,updated_at)
      VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?)
      ON CONFLICT(id) DO UPDATE SET name=excluded.name,prompt=excluded.prompt,
        task_type=excluded.task_type,cron=excluded.cron,interval_ms=excluded.interval_ms,
        provider_id=excluded.provider_id,model_id=excluded.model_id,base_url=excluded.base_url,
        notify_user=excluded.notify_user,enabled=excluded.enabled,next_run_at=excluded.next_run_at,
        claim_id=NULL,claim_until=NULL,updated_at=excluded.updated_at
    `).run(
      id, input.name, input.prompt, input.taskType, input.cron ?? null, input.intervalMs ?? null,
      input.providerId ?? null, input.modelId ?? null, input.baseUrl ?? null,
      input.notifyUser ? 1 : 0, input.enabled === false ? 0 : 1, nextRunAt, timestamp, timestamp,
    );
    return this.getSchedule(id)!;
  }

  patchSchedule(id: string, patch: Record<string, unknown>): ScheduleRecord | undefined {
    const existing = this.getSchedule(id);
    if (!existing) return undefined;
    return this.saveSchedule({
      id,
      name: typeof patch.name === 'string' ? patch.name : existing.name,
      prompt: typeof patch.prompt === 'string' ? patch.prompt : existing.prompt,
      taskType: patch.task_type === 'poll' || patch.task_type === 'scheduled'
        ? patch.task_type : existing.task_type,
      cron: patch.cron === null || typeof patch.cron === 'string' ? patch.cron : existing.cron,
      intervalMs: patch.interval_ms === null || typeof patch.interval_ms === 'number'
        ? patch.interval_ms : existing.interval_ms,
      providerId: patch.provider_id === null || typeof patch.provider_id === 'string'
        ? patch.provider_id : existing.provider_id,
      modelId: patch.model_id === null || typeof patch.model_id === 'string'
        ? patch.model_id : existing.model_id,
      baseUrl: patch.base_url === null || typeof patch.base_url === 'string'
        ? patch.base_url : existing.base_url,
      notifyUser: typeof patch.notify_user === 'boolean' ? patch.notify_user : !!existing.notify_user,
      enabled: typeof patch.enabled === 'boolean' ? patch.enabled : !!existing.enabled,
    });
  }

  deleteSchedule(id: string): boolean {
    return this.db.prepare('DELETE FROM schedules WHERE id = ?').run(id).changes === 1;
  }

  claimDueSchedules(limit: number, leaseMs = 300_000): ScheduleRecord[] {
    const timestamp = now();
    const claimUntil = new Date(Date.now() + leaseMs).toISOString();
    const claimId = randomUUID();
    this.db.exec('BEGIN IMMEDIATE');
    try {
      const due = this.db.prepare(`
        SELECT id FROM schedules
         WHERE enabled=1 AND next_run_at <= ? AND (claim_until IS NULL OR claim_until < ?)
         ORDER BY next_run_at LIMIT ?
      `).all(timestamp, timestamp, limit) as { id: string }[];
      const claim = this.db.prepare('UPDATE schedules SET claim_id=?, claim_until=? WHERE id=?');
      for (const row of due) claim.run(claimId, claimUntil, row.id);
      this.db.exec('COMMIT');
      if (due.length === 0) return [];
      return this.db.prepare(`SELECT * FROM schedules WHERE claim_id = ? ORDER BY next_run_at`)
        .all(claimId) as unknown as ScheduleRecord[];
    } catch (error) {
      this.db.exec('ROLLBACK');
      throw error;
    }
  }

  finishSchedule(schedule: ScheduleRecord, status: string, result: string, nextRunAt: Date): void {
    this.db.prepare(`
      UPDATE schedules SET next_run_at=?,last_run_at=?,run_count=run_count+1,last_status=?,
        last_result=?,claim_id=NULL,claim_until=NULL,updated_at=? WHERE id=? AND claim_id=?
    `).run(nextRunAt.toISOString(), now(), status, result, now(), schedule.id, schedule.claim_id);
  }

  createRun(input: {
    kind: string; conversationId?: string | null; scheduleId?: string | null;
    providerId?: string | null; modelId?: string | null; input: unknown;
  }): string {
    const id = randomUUID();
    this.db.prepare(`
      INSERT INTO runs(id,kind,conversation_id,schedule_id,provider_id,model_id,status,input_json,created_at)
      VALUES(?,?,?,?,?,?,'queued',?,?)
    `).run(
      id, input.kind, input.conversationId ?? null, input.scheduleId ?? null,
      input.providerId ?? null, input.modelId ?? null, json(input.input), now(),
    );
    return id;
  }

  updateRun(id: string, status: string, result?: string | null, error?: string | null): void {
    const terminal = ['completed', 'failed', 'cancelled'].includes(status);
    this.db.prepare(`
      UPDATE runs SET status=?, result=?, error=?,
        started_at=COALESCE(started_at,?), completed_at=? WHERE id=?
    `).run(status, result ?? null, error ?? null, now(), terminal ? now() : null, id);
  }

  addRunEvent(runId: string, eventType: string, payload: unknown): void {
    this.db.prepare(
      'INSERT INTO run_events(run_id,event_type,payload_json,created_at) VALUES(?,?,?,?)',
    ).run(runId, eventType, json(payload), now());
  }

  listRuns(limit = 100): unknown[] {
    return this.db.prepare('SELECT * FROM runs ORDER BY created_at DESC LIMIT ?').all(limit);
  }

  getRun(id: string): unknown {
    const run = this.db.prepare('SELECT * FROM runs WHERE id=?').get(id);
    if (!run) return undefined;
    const events = this.db.prepare('SELECT * FROM run_events WHERE run_id=? ORDER BY id').all(id);
    return { ...run, events };
  }

  ensureConversation(id: string, providerId?: string | null, modelId?: string | null, baseUrl?: string | null): void {
    const timestamp = now();
    this.db.prepare(`
      INSERT INTO conversations(id,provider_id,model_id,base_url,created_at,updated_at)
      VALUES(?,?,?,?,?,?) ON CONFLICT(id) DO UPDATE SET updated_at=excluded.updated_at
    `).run(id, providerId ?? null, modelId ?? null, baseUrl ?? null, timestamp, timestamp);
  }

  addMessage(conversationId: string, role: 'user' | 'assistant' | 'tool', content: string, metadata?: unknown): void {
    this.db.prepare(`
      INSERT INTO messages(id,conversation_id,role,content,metadata_json,created_at) VALUES(?,?,?,?,?,?)
    `).run(randomUUID(), conversationId, role, content, json(metadata), now());
    this.db.prepare('UPDATE conversations SET updated_at=? WHERE id=?').run(now(), conversationId);
  }

  listConversations(): unknown[] {
    return this.db.prepare('SELECT * FROM conversations ORDER BY updated_at DESC LIMIT 100').all();
  }

  getConversation(id: string): unknown {
    const conversation = this.db.prepare('SELECT * FROM conversations WHERE id=?').get(id);
    if (!conversation) return undefined;
    const messages = this.db.prepare(
      'SELECT id,role,content,metadata_json,created_at FROM messages WHERE conversation_id=? ORDER BY created_at',
    ).all(id);
    return { ...conversation, messages };
  }

  deleteConversation(id: string): boolean {
    return this.db.prepare('DELETE FROM conversations WHERE id=?').run(id).changes === 1;
  }

  createNotification(source: string, sourceId: string | null, title: string, body: string): unknown {
    const id = randomUUID();
    this.db.prepare(`
      INSERT INTO notifications(id,source,source_id,title,body,created_at) VALUES(?,?,?,?,?,?)
    `).run(id, source, sourceId, title, body, now());
    return this.db.prepare('SELECT * FROM notifications WHERE id=?').get(id);
  }

  listNotifications(): unknown[] {
    return this.db.prepare('SELECT * FROM notifications ORDER BY created_at DESC LIMIT 100').all();
  }

  markNotification(id: string): boolean {
    return this.db.prepare('UPDATE notifications SET read=1 WHERE id=?').run(id).changes === 1;
  }

  createPendingAction(
    runId: string | null,
    actionType: string,
    summary: string,
    payload: unknown,
    options?: {
      sessionId?: string | null;
      origin?: 'local' | 'composio';
      registryVersion?: string;
      parametersHash?: string;
      actionHash?: string;
      capabilities?: unknown;
      workspaceBookmarkId?: string | null;
      ttlMs?: number;
    },
  ): PendingActionRecord {
    const id = randomUUID();
    const normalized = json(payload);
    const parametersHash = options?.parametersHash
      ?? createHash('sha256').update(normalized).digest('hex');
    const registryVersion = options?.registryVersion ?? '1';
    const actionHash = options?.actionHash
      ?? createHash('sha256').update(`${registryVersion}\n${actionType}\n${normalized}`).digest('hex');
    const expiresAt = new Date(Date.now() + (options?.ttlMs ?? 120_000)).toISOString();
    this.db.prepare(`
      INSERT INTO pending_actions(
        id,run_id,session_id,action_origin,action_type,summary,payload_json,
        normalized_parameters_json,parameters_hash,action_hash,registry_version,
        capabilities_json,workspace_bookmark_id,status,idempotency_key,expires_at,created_at
      ) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,'pending',?,?,?)
    `).run(
      id, runId, options?.sessionId ?? null, options?.origin ?? 'composio',
      actionType, summary, normalized, normalized, parametersHash, actionHash,
      registryVersion, options?.capabilities === undefined ? null : json(options.capabilities),
      options?.workspaceBookmarkId ?? null, randomUUID(), expiresAt, now(),
    );
    return this.getPendingAction(id)!;
  }

  getPendingAction(id: string): PendingActionRecord | undefined {
    this.expirePendingActions();
    return this.db.prepare('SELECT * FROM pending_actions WHERE id=?')
      .get(id) as unknown as PendingActionRecord | undefined;
  }

  expirePendingActions(): number {
    return Number(this.db.prepare(`
      UPDATE pending_actions SET status='expired',resolved_at=?
       WHERE status='pending' AND expires_at <= ?
    `).run(now(), now()).changes);
  }

  resolvePendingAction(
    id: string,
    status: 'approved' | 'rejected',
    decision?: unknown,
  ): boolean {
    this.expirePendingActions();
    return this.db.prepare(`
      UPDATE pending_actions SET status=?,decision_json=?,resolved_at=?
       WHERE id=? AND status='pending' AND expires_at > ?
    `).run(status, decision === undefined ? null : json(decision), now(), id, now()).changes === 1;
  }

  claimPendingAction(id: string): PendingActionRecord | undefined {
    const requestId = randomUUID();
    const result = this.db.prepare(`
      UPDATE pending_actions SET status='executing',execution_request_id=?
       WHERE id=? AND status='approved' AND execution_request_id IS NULL
    `).run(requestId, id);
    return result.changes === 1 ? this.getPendingAction(id) : undefined;
  }

  finishPendingAction(
    id: string,
    requestId: string,
    status: 'completed' | 'failed',
    result?: unknown,
    error?: string,
  ): boolean {
    return this.db.prepare(`
      UPDATE pending_actions SET status=?,result_json=?,error=?,executed_at=?
       WHERE id=? AND status='executing' AND execution_request_id=?
    `).run(status, result === undefined ? null : json(result), error ?? null, now(), id, requestId).changes === 1;
  }

  listConnections(): unknown[] {
    return this.db.prepare('SELECT * FROM connections ORDER BY app_type').all();
  }

  saveConnection(appType: string, status: string, externalAccountId?: string | null, metadata?: unknown): unknown {
    const timestamp = now();
    this.db.prepare(`
      INSERT INTO connections(id,app_type,status,external_account_id,metadata_json,created_at,updated_at)
      VALUES(?,?,?,?,?,?,?) ON CONFLICT(app_type) DO UPDATE SET status=excluded.status,
        external_account_id=excluded.external_account_id,metadata_json=excluded.metadata_json,
        updated_at=excluded.updated_at
    `).run(randomUUID(), appType, status, externalAccountId ?? null, json(metadata), timestamp, timestamp);
    return this.db.prepare('SELECT * FROM connections WHERE app_type=?').get(appType);
  }
}
