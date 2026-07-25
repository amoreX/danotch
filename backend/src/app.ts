import { createHash, randomUUID } from 'node:crypto';
import express, { type Express, type NextFunction, type Request, type Response } from 'express';
import { rateLimit } from 'express-rate-limit';
import type { Config } from './config.js';
import type { ProviderPreference, Repositories, ScheduleRecord } from './db/repositories.js';
import type { NotchBridge } from './events/notch.js';
import type { Credential, SecretBroker } from './ipc/keychain-broker.js';
import { runChat } from './agent/runner.js';
import { createProvider, validateProviderEndpoint } from './providers/factory.js';
import type { ProviderType } from './providers/types.js';
import { isCronAtLeastInterval, isValidCron, scheduleToHuman } from './scheduler/compute-next.js';
import { SessionManager } from './security/session.js';
import type { ActionCoordinator } from './actions/coordinator.js';
import { COMPOSIO_APPS, type LocalComposioService } from './composio/service.js';

export interface AppDependencies {
  config: Config;
  repositories: Repositories;
  broker: SecretBroker;
  sessions: SessionManager;
  events: NotchBridge;
  getPort: () => number;
  instanceId: string;
  actions: ActionCoordinator;
  composio: LocalComposioService;
  verifyProviderCredential?: (input: {
    provider: ProviderType;
    modelId: string;
    baseUrl: string | null;
    apiKey: string;
  }) => Promise<void>;
}

const PROVIDERS = new Set<ProviderType>(['anthropic', 'openai', 'openrouter', 'deepseek', 'custom']);
type ExternalProvider = 'anthropic' | 'openai' | 'openrouter' | 'deepseek' | 'custom_openai';
const EXTERNAL_PROVIDERS = new Set<ExternalProvider>([
  'anthropic', 'openai', 'openrouter', 'deepseek', 'custom_openai',
]);
const safeId = (value: unknown) => typeof value === 'string' && /^[A-Za-z0-9_-]{1,128}$/.test(value);
const safeText = (value: unknown, max: number) => typeof value === 'string' && value.length > 0 && value.length <= max;

export function createApp(deps: AppDependencies): Express {
  const { config, repositories: repos, sessions } = deps;
  const app = express();
  app.disable('x-powered-by');
  app.disable('etag');
  app.set('trust proxy', false);

  app.use((req, res, next) => {
    const port = deps.getPort();
    if (port > 0 && req.headers.host !== `127.0.0.1:${port}`) {
      res.status(400).json({ error: 'Invalid Host header' });
      return;
    }
    const origin = req.headers.origin;
    if (origin !== config.allowedOrigin) {
      res.status(403).json({ error: 'Invalid Origin header' });
      return;
    }
    if ('access-control-request-method' in req.headers) {
      res.status(403).json({ error: 'CORS is not supported' });
      return;
    }
    next();
  });
  app.use(express.json({ limit: config.jsonBodyLimit, strict: true }));
  app.use((req, res, next) => {
    res.setHeader('X-Content-Type-Options', 'nosniff');
    res.setHeader('X-Frame-Options', 'DENY');
    res.setHeader('Referrer-Policy', 'no-referrer');
    res.setHeader('Permissions-Policy', 'camera=(), microphone=(), geolocation=()');
    res.setHeader('Cache-Control', 'no-store');
    res.setHeader('Content-Security-Policy', "default-src 'none'; frame-ancestors 'none'");
    res.setHeader('Cross-Origin-Resource-Policy', 'same-origin');
    next();
  });
  app.use(rateLimit({
    windowMs: config.httpRateWindowMs,
    limit: config.httpRateLimit,
    standardHeaders: true,
    legacyHeaders: false,
    keyGenerator: () => 'local-user',
  }));
  app.use(correlation);
  app.use(requestLog);

  const exchangeLimiter = rateLimit({
    windowMs: 60_000,
    limit: 10,
    standardHeaders: true,
    legacyHeaders: false,
    keyGenerator: () => 'bootstrap',
  });
  app.post('/ipc/session', exchangeLimiter, (req, res) => {
    const result = sessions.exchange(req.body?.installationSecret);
    if (!result) {
      res.status(401).json({ error: 'Invalid installation secret' });
      return;
    }
    res.json({ ...result, protocolVersion: config.protocolVersion });
  });
  app.post('/v1/session', exchangeLimiter, (req, res) => {
    const body = req.body as Record<string, unknown>;
    if (
      !safeText(body.installation_id, 128)
      || body.instance_id !== deps.instanceId
      || !Array.isArray(body.protocol_versions)
      || !body.protocol_versions.includes(config.protocolVersion)
    ) {
      res.status(400).json({ error: 'Invalid local session negotiation' });
      return;
    }
    const result = sessions.exchange(body.installation_secret);
    if (!result) {
      res.status(401).json({ error: 'Invalid installation secret' });
      return;
    }
    res.json({
      session_token: result.token,
      expires_at: result.expiresAt,
      protocol_version: config.protocolVersion,
      websocket_path: '/v1/events',
    });
  });

  // Readiness exposes no user data and is needed by the source installer
  // before an app session exists. Host and Origin validation still apply.
  app.get('/health/live', (_req, res) => {
    res.json({ status: 'ok', protocolVersion: config.protocolVersion });
  });
  app.get('/health/ready', (_req, res) => {
    res.json({ status: 'ready', storage: 'sqlite', broker: 'native' });
  });

  app.use(sessions.middleware);
  app.use((req, res, next) => {
    const allowsCredential = (req.path === '/v1/config/providers' && req.method === 'PUT')
      || (req.path === '/v1/config/providers/verify' && req.method === 'POST')
      || (req.path === '/v1/config/composio' && req.method === 'PUT');
    if (!allowsCredential) {
      try {
        rejectSecretFields(req.body);
      } catch (error) {
        res.status(400).json({ error: publicError(error) });
        return;
      }
    }
    next();
  });
  app.get('/v1/config/providers', (_req, res) => {
    res.json({ providers: repos.listProviders().map(providerPayload) });
  });
  app.put('/v1/config/providers', async (req, res) => {
    let credential: Credential | undefined;
    let previous: string | undefined;
    try {
      const input = await localProviderInput(req.body, true);
      credential = providerCredential(input.externalProvider);
      previous = await deps.broker.getCredential(credential);
      await deps.broker.setCredential(credential, input.apiKey!);
      const provider = repos.saveProvider({
        id: input.externalProvider,
        provider: input.provider,
        modelId: input.modelId,
        baseUrl: input.baseUrl,
        keychainAccount: credential,
        active: true,
      });
      res.json({ provider: providerPayload(provider), saved: true });
    } catch (error) {
      if (credential) {
        try {
          if (previous !== undefined) await deps.broker.setCredential(credential, previous);
          else await deps.broker.deleteCredential(credential);
        } catch {
          // The original operation still fails closed.
        }
      }
      res.status(400).json({
        error: credentialSafeError(error, [req.body?.api_key]),
        saved: false,
      });
    }
  });
  app.post('/v1/config/providers/verify', async (req, res) => {
    try {
      const input = await localProviderInput(req.body, true);
      if (deps.verifyProviderCredential) {
        await deps.verifyProviderCredential({
          provider: input.provider,
          modelId: input.modelId,
          baseUrl: input.baseUrl,
          apiKey: input.apiKey!,
        });
      } else {
        const provider = createProvider(input.provider, input.apiKey!, input.modelId, input.baseUrl);
        await provider.complete({
          messages: [{ role: 'user', content: 'Reply with OK.' }],
          systemPrompt: 'Return only OK.',
          maxTokens: 8,
        });
      }
      res.json({
        verified: true,
        provider: input.externalProvider,
        model_id: input.modelId,
      });
    } catch (error) {
      res.status(400).json({
        verified: false,
        error: credentialSafeError(error, [req.body?.api_key]),
      });
    }
  });
  app.post('/v1/config/providers/activate', (req, res) => {
    try {
      const provider = internalProvider(req.body?.provider);
      if (!repos.activateProviderType(provider)) {
        res.status(404).json({ error: 'Provider not configured' });
        return;
      }
      res.json({ activated: true, provider: externalProvider(provider) });
    } catch (error) {
      res.status(400).json({ error: publicError(error) });
    }
  });
  app.get('/v1/config/providers/models', (_req, res) => {
    const selected = repos.getProvider();
    const provider = selected ? externalProvider(selected.provider) : 'anthropic';
    const configuredModel = selected?.model_id;
    const models = modelOptions(provider, configuredModel);
    res.json({ provider, active_model: configuredModel ?? null, models });
  });
  app.delete('/v1/config/providers/:provider', async (req, res) => {
    try {
      const provider = internalProvider(req.params.provider);
      const credential = providerCredential(externalProvider(provider));
      await deps.broker.deleteCredential(credential);
      if (!repos.deleteProviderType(provider)) {
        res.status(404).json({ error: 'Provider not configured' });
        return;
      }
      res.json({ deleted: true, provider: externalProvider(provider) });
    } catch (error) {
      res.status(400).json({ error: publicError(error) });
    }
  });

  app.get('/api/provider', (_req, res) => {
    const providers = repos.listProviders();
    res.json({ providers, configs: providers });
  });
  app.get('/api/provider/models', (req, res) => {
    const selected = repos.getProvider(typeof req.query.provider_id === 'string' ? req.query.provider_id : undefined);
    const models = selected ? [selected.model_id] : [];
    res.json({ models });
  });
  app.post('/api/provider', async (req, res) => {
    try {
      rejectSecretFields(req.body);
      const input = await providerInput(req.body);
      const provider = repos.saveProvider(input);
      res.status(201).json({ provider });
    } catch (error) {
      res.status(400).json({ error: publicError(error) });
    }
  });
  app.post('/api/provider/verify', async (req, res) => {
    try {
      rejectSecretFields(req.body);
      const input = await providerInput(req.body);
      const secret = await deps.broker.getCredential(input.keychainAccount as Credential);
      if (!secret) throw new Error('Provider credential is not configured');
      const provider = createProvider(input.provider, secret, input.modelId, input.baseUrl);
      await provider.complete({
        messages: [{ role: 'user', content: 'Reply with OK.' }],
        systemPrompt: 'Return only OK.',
        maxTokens: 8,
      });
      if (safeId(req.body.id)) repos.markProviderVerified(req.body.id);
      res.json({ ok: true });
    } catch (error) {
      res.status(400).json({ error: publicError(error) });
    }
  });
  app.post('/api/provider/activate', (req, res) => {
    if (!safeId(req.body?.id) || !repos.activateProvider(req.body.id)) {
      res.status(404).json({ error: 'Provider not found' });
      return;
    }
    res.json({ ok: true });
  });
  app.post('/api/provider/default', (_req, res) => {
    res.status(409).json({ error: 'No server-owned fallback provider exists' });
  });
  app.delete('/api/provider/:id', (req, res) => {
    res.status(repos.deleteProvider(String(req.params.id)) ? 200 : 404).json({ ok: true });
  });
  app.delete('/api/provider', (req, res) => {
    const id = safeId(req.body?.id) ? req.body.id as string : undefined;
    if (!id) {
      res.status(400).json({ error: 'Provider id is required' });
      return;
    }
    res.status(repos.deleteProvider(id) ? 200 : 404).json({ ok: true });
  });

  app.post('/api/chat', (req, res) => void handleChat(req, res, deps));
  app.post('/v1/chat', (req, res) => void handleChat(req, res, deps));

  app.get('/api/threads', (_req, res) => res.json({ threads: repos.listConversations() }));
  app.get('/api/threads/:id', (req, res) => {
    const value = repos.getConversation(String(req.params.id));
    res.status(value ? 200 : 404).json(value ? value : { error: 'Conversation not found' });
  });
  app.delete('/api/threads/:id', (req, res) => {
    res.status(repos.deleteConversation(String(req.params.id)) ? 200 : 404).json({ ok: true });
  });

  app.get(['/api/scheduled', '/v1/scheduled'], (_req, res) => {
    const tasks = repos.listSchedules().map((task) => schedulePayload(task, repos));
    res.json({ tasks });
  });
  app.post(['/api/scheduled', '/v1/scheduled'], (req, res) => void saveSchedule(req, res, deps));
  app.patch(['/api/scheduled/:id', '/v1/scheduled/:id'], async (req, res) => {
    try {
      const normalized = normalizeScheduleProvider(req.body, repos);
      const merged = { ...repos.getSchedule(String(req.params.id)), ...normalized };
      await validateSchedule(merged, config, repos);
      const task = repos.patchSchedule(String(req.params.id), normalized);
      res.status(task ? 200 : 404).json(
        task ? { task: schedulePayload(task, repos) } : { error: 'Scheduled task not found' },
      );
    } catch (error) {
      res.status(400).json({ error: publicError(error) });
    }
  });
  app.delete(['/api/scheduled/:id', '/v1/scheduled/:id'], (req, res) => {
    res.status(repos.deleteSchedule(String(req.params.id)) ? 200 : 404).json({ ok: true });
  });
  app.post(['/api/scheduled/:id/run', '/v1/scheduled/:id/run'], (req, res) => {
    const task = repos.getSchedule(String(req.params.id));
    if (!task) {
      res.status(404).json({ error: 'Scheduled task not found' });
      return;
    }
    repos.db.prepare('UPDATE schedules SET next_run_at=?,claim_id=NULL,claim_until=NULL WHERE id=?')
      .run(new Date().toISOString(), task.id);
    res.json({ ok: true });
  });

  app.get(['/api/notifications', '/v1/notifications'], (_req, res) => {
    const notifications = repos.listNotifications().map((item) => {
      const value = item as Record<string, unknown>;
      return { ...value, read: value.read === 1 };
    });
    res.json({ notifications });
  });
  app.get(['/api/notifications/unread-count', '/v1/notifications/unread-count'], (_req, res) => {
    const row = repos.db.prepare('SELECT COUNT(*) count FROM notifications WHERE read=0').get() as { count: number };
    res.json({ count: row.count });
  });
  app.post(['/api/notifications/:id/read', '/v1/notifications/:id/read'], (req, res) => {
    res.status(repos.markNotification(String(req.params.id)) ? 200 : 404).json({ ok: true });
  });
  app.post(['/api/notifications/read-all', '/v1/notifications/read-all'], (_req, res) => {
    repos.db.exec('UPDATE notifications SET read=1');
    res.json({ ok: true });
  });
  app.delete(['/api/notifications/all', '/v1/notifications/all'], (_req, res) => {
    repos.db.exec('DELETE FROM notifications');
    res.json({ ok: true });
  });

  app.get('/api/runs', (_req, res) => res.json({ runs: repos.listRuns() }));
  app.get('/api/runs/:id', (req, res) => {
    const run = repos.getRun(String(req.params.id));
    res.status(run ? 200 : 404).json(run ? { run } : { error: 'Run not found' });
  });
  app.get('/api/actions', (_req, res) => {
    const actions = repos.db.prepare('SELECT * FROM pending_actions ORDER BY created_at DESC').all();
    res.json({ actions });
  });
  app.post('/api/actions/:id/approve', (req, res) => void approveComposioAction(req, res, deps));
  app.post('/api/actions/:id/reject', (req, res) => {
    res.status(repos.resolvePendingAction(String(req.params.id), 'rejected') ? 200 : 409).json({ ok: true });
  });
  app.post('/v1/actions/:id/:decision', (req, res) => {
    const decision = req.params.decision === 'approve' ? 'approved'
      : req.params.decision === 'reject' ? 'rejected' : undefined;
    if (!decision) {
      res.status(400).json({ error: 'Decision must be approve or reject' });
      return;
    }
    if (decision === 'approved') {
      void approveComposioAction(req, res, deps);
      return;
    }
    const resolved = repos.resolvePendingAction(String(req.params.id), decision);
    res.status(resolved ? 200 : 409).json({ ok: resolved, decision });
  });

  app.get('/api/apps', (_req, res) => res.json({ connections: repos.listConnections() }));
  app.get(['/api/apps/:appType/status', '/v1/integrations/:appType'], async (req, res) => {
    try {
      const status = await deps.composio.status(String(req.params.appType));
      res.status(status.available ? 200 : status.status === 'not_configured' ? 200 : 503).json(status);
    } catch (error) {
      res.status(400).json({ error: publicError(error) });
    }
  });
  app.post(['/api/apps/:appType/connect', '/v1/integrations/:appType/connect'], async (req, res) => {
    try {
      res.json(await deps.composio.connect(String(req.params.appType)));
    } catch (error) {
      res.status(503).json({ error: publicError(error), connected: false });
    }
  });
  app.post(['/api/apps/:appType/disconnect', '/v1/integrations/:appType/disconnect'], async (req, res) => {
    try {
      res.json(await deps.composio.disconnect(String(req.params.appType)));
    } catch (error) {
      res.status(503).json({ error: publicError(error), disconnected: false });
    }
  });

  app.get('/v1/config/composio', async (_req, res) => {
    try {
      const configured = Boolean(await deps.broker.getCredential('composio'));
      const connectedApps = (repos.listConnections() as Record<string, unknown>[])
        .filter((item) => item.status === 'connected')
        .map((item) => String(item.app_type));
      res.json({
        configured,
        connected_apps: connectedApps,
        ...deps.composio.metadata(),
      });
    } catch {
      res.json({ configured: false, connected_apps: [] });
    }
  });
  app.put('/v1/config/composio', async (req, res) => {
    try {
      rejectUnexpectedSecretFields(req.body ?? {}, new Set(['api_key']));
      const apiKey = req.body?.api_key;
      const replacingKey = apiKey !== undefined;
      if (replacingKey) {
        if (!safeText(apiKey, 16_384)) throw new Error('api_key must be a non-empty string');
        await deps.broker.setCredential('composio', apiKey);
        // A different Composio project cannot safely inherit account IDs from
        // the previous key. Preserve auth-config choices but require relinking.
        for (const app of COMPOSIO_APPS) deps.repositories.clearConnection(app.appType);
      } else if (!await deps.broker.getCredential('composio')) {
        throw new Error('api_key is required before configuring integrations');
      }
      deps.composio.saveAuthConfigs(req.body?.auth_config_ids);
      const connectedApps = (repos.listConnections() as Record<string, unknown>[])
        .filter((item) => item.status === 'connected')
        .map((item) => String(item.app_type));
      res.json({
        configured: true,
        connected_apps: connectedApps,
        ...deps.composio.metadata(),
      });
    } catch (error) {
      const message = credentialSafeError(error, [req.body?.api_key]);
      res.status(/api_key|secret field/i.test(message) ? 400 : 503)
        .json({ error: message, configured: false });
    }
  });

  app.use((_req, res) => res.status(404).json({ error: 'Not found' }));
  app.use((error: Error & { type?: string }, _req: Request, res: Response, _next: NextFunction) => {
    if (error.type === 'entity.too.large') {
      res.status(413).json({ error: 'Request body too large' });
      return;
    }
    res.status(400).json({ error: 'Invalid request body' });
  });
  return app;
}

async function approveComposioAction(
  req: Request,
  res: Response,
  deps: AppDependencies,
): Promise<void> {
  const id = String(req.params.id);
  const action = deps.repositories.getPendingAction(id);
  if (!action || action.action_origin !== 'composio' || action.status !== 'pending') {
    res.status(409).json({ error: 'Action is not pending' });
    return;
  }
  if (!deps.repositories.resolvePendingAction(id, 'approved', { source: 'local_api' })) {
    res.status(409).json({ error: 'Action is not pending' });
    return;
  }
  const claimed = deps.repositories.claimPendingAction(id);
  if (!claimed) {
    res.status(409).json({ error: 'Action was already claimed' });
    return;
  }
  try {
    const result = await deps.composio.execute(
      claimed.action_type,
      JSON.parse(claimed.normalized_parameters_json) as Record<string, unknown>,
      claimed.idempotency_key,
    );
    deps.repositories.finishPendingAction(id, claimed.execution_request_id!, 'completed', result);
    res.json({ ok: true, decision: 'approved', status: 'completed', result });
  } catch {
    deps.repositories.finishPendingAction(
      id,
      claimed.execution_request_id!,
      'failed',
      undefined,
      'Integration action failed; delivery outcome may require reconciliation',
    );
    res.status(502).json({ error: 'Integration action failed', status: 'failed' });
  }
}

function correlation(_req: Request, res: Response, next: NextFunction): void {
  res.setHeader('X-Request-ID', randomUUID());
  next();
}

function requestLog(req: Request, res: Response, next: NextFunction): void {
  const path = req.path.replace(/\/[A-Za-z0-9_-]{8,}(?=\/|$)/g, '/:id');
  const requestId = String(res.getHeader('X-Request-ID'));
  const id = createHash('sha256').update(requestId).digest('hex').slice(0, 12);
  console.error(`[perch-daemon] ${req.method} ${path} rid=${id}`);
  next();
}

function rejectSecretFields(body: unknown): void {
  if (!body || typeof body !== 'object') return;
  for (const [key, value] of Object.entries(body as Record<string, unknown>)) {
    if (/api.?key|secret|token|password|credential/i.test(key)) {
      throw new Error('Secrets must be stored by the native Keychain host');
    }
    if (value && typeof value === 'object') rejectSecretFields(value);
  }
}

async function providerInput(body: Record<string, unknown>) {
  if (!PROVIDERS.has(body.provider as ProviderType)) throw new Error('Unsupported provider');
  if (!safeText(body.model_id, 200)) throw new Error('model_id is required');
  if (!safeText(body.keychain_account, 256)) throw new Error('keychain_account is required');
  const provider = body.provider as ProviderType;
  let baseUrl = typeof body.base_url === 'string' ? body.base_url : null;
  if (provider === 'custom') baseUrl = await validateProviderEndpoint(baseUrl ?? '');
  else if (baseUrl) throw new Error('base_url is only accepted for custom providers');
  return {
    id: safeId(body.id) ? body.id as string : undefined,
    provider,
    modelId: body.model_id as string,
    baseUrl,
    keychainAccount: body.keychain_account as string,
    active: body.is_active === true,
  };
}

function validHistory(value: unknown): value is { role: 'user' | 'assistant'; content: string } {
  if (!value || typeof value !== 'object') return false;
  const item = value as Record<string, unknown>;
  return (item.role === 'user' || item.role === 'assistant') && safeText(item.content, 100_000);
}

async function validateSchedule(
  body: Record<string, unknown>,
  config: Config,
  repos: Repositories,
): Promise<void> {
  if (!safeText(body.name, 200) || !safeText(body.prompt, 100_000)) {
    throw new Error('name and prompt are required');
  }
  const cron = typeof body.cron === 'string' ? body.cron : null;
  const interval = typeof body.interval_ms === 'number' ? body.interval_ms : null;
  if ((cron === null) === (interval === null)) throw new Error('Exactly one of cron or interval_ms is required');
  if (cron && (!isValidCron(cron) || !isCronAtLeastInterval(cron, config.scheduler.minIntervalMs))) {
    throw new Error('Cron is invalid or runs too frequently');
  }
  if (interval !== null && (!Number.isSafeInteger(interval) || interval < config.scheduler.minIntervalMs)) {
    throw new Error(`interval_ms must be at least ${config.scheduler.minIntervalMs}`);
  }
  if (body.base_url !== null && body.base_url !== undefined) {
    if (!safeText(body.base_url, 2048)) throw new Error('base_url is invalid');
    const provider = repos.getProvider(typeof body.provider_id === 'string' ? body.provider_id : undefined);
    if (!provider || (provider.provider !== 'custom' && provider.provider !== 'deepseek')) {
      throw new Error('base_url overrides require custom_openai or deepseek');
    }
    body.base_url = await validateProviderEndpoint(body.base_url as string);
  }
}

async function saveSchedule(req: Request, res: Response, deps: AppDependencies): Promise<void> {
  try {
    const body = normalizeScheduleProvider(req.body, deps.repositories);
    await validateSchedule(body, deps.config, deps.repositories);
    const task = deps.repositories.saveSchedule({
      name: body.name as string,
      prompt: body.prompt as string,
      taskType: body.task_type === 'poll' ? 'poll' : 'scheduled',
      cron: body.cron as string | undefined,
      intervalMs: body.interval_ms as number | undefined,
      providerId: safeId(body.provider_id) ? body.provider_id as string : null,
      modelId: safeText(body.model_id, 200) ? body.model_id as string : null,
      baseUrl: safeText(body.base_url, 2048) ? body.base_url as string : null,
      notifyUser: body.notify_user === true,
      enabled: body.enabled !== false,
    });
    res.status(201).json({ task: schedulePayload(task, deps.repositories) });
  } catch (error) {
    res.status(400).json({ error: publicError(error) });
  }
}

function publicError(error: unknown): string {
  return error instanceof Error ? error.message.slice(0, 300) : 'Request failed';
}

function credentialSafeError(error: unknown, secrets: unknown[]): string {
  let message = publicError(error);
  for (const secret of secrets) {
    if (typeof secret === 'string' && secret.length > 0) message = message.replaceAll(secret, '[redacted]');
  }
  return message;
}

async function handleChat(req: Request, res: Response, deps: AppDependencies): Promise<void> {
  if (!safeText(req.body?.message, 100_000)) {
    res.status(400).json({ error: 'message is required and must be at most 100000 characters' });
    return;
  }
  try {
    let providerId = safeId(req.body.provider_id) ? req.body.provider_id as string : undefined;
    if (typeof req.body.provider === 'string') {
      const preference = deps.repositories.getProviderByType(internalProvider(req.body.provider));
      if (!preference) throw new Error('Requested provider is not configured');
      providerId = preference.id;
    }
    const history = Array.isArray(req.body.history)
      ? req.body.history.filter(validHistory).slice(-24)
      : [];
    const task = await runChat({
      message: req.body.message,
      sessionId: safeId(req.body.session_id) ? req.body.session_id : undefined,
      conversationId: safeId(req.body.conversation_id) ? req.body.conversation_id : undefined,
      providerId,
      modelId: safeText(req.body.model_id, 200) ? req.body.model_id : undefined,
      baseUrl: safeText(req.body.base_url, 2048) ? req.body.base_url : undefined,
      history,
    }, deps);
    res.json({
      task: { id: task.id, status: task.status, result: task.result, error: task.error },
      thread_id: task.conversationId,
      conversation_id: task.conversationId,
    });
  } catch (error) {
    res.status(409).json({ error: publicError(error) });
  }
}

function internalProvider(value: unknown): ProviderType {
  const external = value === 'custom' ? 'custom_openai' : value;
  if (!EXTERNAL_PROVIDERS.has(external as ExternalProvider)) throw new Error('Unsupported provider');
  return external === 'custom_openai' ? 'custom' : external as ProviderType;
}

function externalProvider(provider: ProviderType): ExternalProvider {
  return provider === 'custom' ? 'custom_openai' : provider;
}

function providerCredential(provider: ExternalProvider): Credential {
  return `provider.${provider}` as Credential;
}

async function localProviderInput(body: Record<string, unknown>, requireApiKey: boolean) {
  rejectUnexpectedSecretFields(body, new Set(['api_key']));
  const provider = internalProvider(body.provider);
  const external = externalProvider(provider);
  if (!safeText(body.model_id, 200)) throw new Error('model_id is required');
  if (requireApiKey && !safeText(body.api_key, 16_384)) throw new Error('api_key is required');
  let baseUrl = typeof body.base_url === 'string' ? body.base_url : null;
  if (provider === 'custom') baseUrl = await validateProviderEndpoint(baseUrl ?? '');
  else if (provider === 'deepseek' && baseUrl) baseUrl = await validateProviderEndpoint(baseUrl);
  else if (baseUrl && provider !== 'deepseek') throw new Error('base_url is only accepted for custom_openai or deepseek');
  return {
    provider,
    externalProvider: external,
    modelId: body.model_id as string,
    baseUrl,
    apiKey: requireApiKey ? body.api_key as string : undefined,
  };
}

function rejectUnexpectedSecretFields(body: Record<string, unknown>, allowed: ReadonlySet<string>): void {
  for (const [key, value] of Object.entries(body)) {
    if (/api.?key|secret|token|password|credential/i.test(key) && !allowed.has(key)) {
      throw new Error('Unexpected secret field');
    }
    if (value && typeof value === 'object' && !Array.isArray(value)) {
      rejectUnexpectedSecretFields(value as Record<string, unknown>, new Set());
    }
  }
}

function providerPayload(provider: ProviderPreference): Record<string, unknown> {
  return {
    id: externalProvider(provider.provider),
    provider: externalProvider(provider.provider),
    model_id: provider.model_id,
    base_url: provider.base_url,
    is_active: provider.is_active === 1,
    verified_at: provider.verified_at,
  };
}

function modelOptions(provider: ExternalProvider, configured?: string): Record<string, unknown>[] {
  const defaults: Record<ExternalProvider, string[]> = {
    anthropic: ['claude-sonnet-4-6', 'claude-opus-4-6'],
    openai: ['gpt-5', 'gpt-5-mini'],
    openrouter: ['anthropic/claude-sonnet-4-6'],
    deepseek: ['deepseek-chat', 'deepseek-reasoner'],
    custom_openai: [],
  };
  const ids = [...defaults[provider]];
  if (configured && !ids.includes(configured)) ids.unshift(configured);
  return ids.map((id) => ({ id, name: id }));
}

function normalizeScheduleProvider(
  body: Record<string, unknown>,
  repos: Repositories,
): Record<string, unknown> {
  const normalized = { ...body };
  if (typeof body.provider === 'string') {
    const preference = repos.getProviderByType(internalProvider(body.provider));
    if (!preference) throw new Error('Scheduled provider is not configured');
    normalized.provider_id = preference.id;
  }
  return normalized;
}

function schedulePayload(
  task: ScheduleRecord,
  repos: Repositories,
): Record<string, unknown> {
  const provider = task.provider_id ? repos.getProvider(task.provider_id) : repos.getProvider();
  return {
    ...task,
    enabled: task.enabled === 1,
    notify_user: task.notify_user === 1,
    provider: provider ? externalProvider(provider.provider) : null,
    schedule_human: scheduleToHuman(task.task_type, task.cron, task.interval_ms),
    last_result: task.last_result === null
      ? null
      : { status: task.last_status, summary: task.last_result },
  };
}
